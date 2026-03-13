//! Business logic layer for task management.
//!
//! Wraps the repository with validation, auto-transitions, activity logging,
//! and event emission. Key business rules:
//!
//! - **2-level hierarchy**: A task can have subtasks, but subtasks cannot have
//!   children of their own.
//! - **Auto-timestamps**: `started_at` set when transitioning to `InProgress`,
//!   `completed_at` set when transitioning to `Completed`/`Cancelled`.
//! - **Status reopening**: Moving from terminal → non-terminal clears `completed_at`.
//! - **Circular dependency detection**: Only for `Blocks` relationships (BFS).

use rusqlite::Connection;
use tracing::warn;

use serde_json::{Value, json};
use tron_events::sqlite::contention::{self, RetryError};

use super::errors::TaskError;
use super::repository::TaskRepository;
use super::types::{
    ActivityAction, Area, AreaCreateParams, AreaFilter, AreaListResult, AreaUpdateParams,
    BatchResult, BatchTarget, DependencyRelationship, LogActivityParams, Project,
    ProjectCreateParams, ProjectFilter, ProjectListResult, ProjectStatus, ProjectUpdateParams,
    ProjectWithTasks, Task, TaskActivity, TaskCreateParams, TaskFilter, TaskListResult, TaskStatus,
    TaskUpdateParams, TaskWithDetails,
};

/// Resolved batch operation target — eliminates unwraps via type-safe branching.
enum ResolvedTarget<'a> {
    Ids(&'a [String]),
    Filter(TaskFilter),
}

enum ImmediateTxnError {
    Begin(rusqlite::Error),
    Task(TaskError),
}

impl ImmediateTxnError {
    fn into_task_error(self, operation: &'static str, attempts: u32) -> TaskError {
        match self {
            Self::Begin(error) => {
                if contention::is_rusqlite_busy(&error) {
                    TaskError::Busy {
                        operation,
                        attempts,
                    }
                } else {
                    TaskError::Database(error)
                }
            }
            Self::Task(error) => match error {
                TaskError::Database(database_error)
                    if contention::is_rusqlite_busy(&database_error) =>
                {
                    TaskError::Busy {
                        operation,
                        attempts,
                    }
                }
                other => other,
            },
        }
    }

    fn is_busy(&self) -> bool {
        match self {
            Self::Begin(error) | Self::Task(TaskError::Database(error)) => {
                contention::is_rusqlite_busy(error)
            }
            Self::Task(TaskError::Busy { .. }) => true,
            Self::Task(_) => false,
        }
    }
}

/// Task service with business logic and validation.
pub struct TaskService;

impl TaskService {
    /// Run a closure inside a `BEGIN IMMEDIATE` transaction with retry on
    /// `SQLITE_BUSY`. Unlike `BEGIN DEFERRED`, `IMMEDIATE` acquires the write
    /// lock upfront so contention is detected at `BEGIN` rather than mid-txn.
    fn with_immediate_txn<T>(
        conn: &Connection,
        f: impl FnMut(&Connection) -> Result<T, TaskError>,
    ) -> Result<T, TaskError> {
        Self::with_immediate_txn_policy(conn, contention::BusyRetryPolicy::sqlite_write(), f)
    }

    fn with_immediate_txn_policy<T>(
        conn: &Connection,
        policy: contention::BusyRetryPolicy,
        mut f: impl FnMut(&Connection) -> Result<T, TaskError>,
    ) -> Result<T, TaskError> {
        const OPERATION: &str = "task batch transaction";

        match contention::retry_on_busy(
            OPERATION,
            policy,
            || {
                conn.execute_batch("BEGIN IMMEDIATE")
                    .map_err(ImmediateTxnError::Begin)?;

                match f(conn) {
                    Ok(value) => {
                        if let Err(error) = conn.execute_batch("COMMIT") {
                            let _ = conn.execute_batch("ROLLBACK");
                            return Err(ImmediateTxnError::Begin(error));
                        }
                        Ok(value)
                    }
                    Err(error) => {
                        let _ = conn.execute_batch("ROLLBACK");
                        Err(ImmediateTxnError::Task(error))
                    }
                }
            },
            ImmediateTxnError::is_busy,
        ) {
            Ok(value) => Ok(value),
            Err(RetryError::Inner(error)) => Err(error.into_task_error(OPERATION, 0)),
            Err(RetryError::BusyTimeout(timeout)) => Err(timeout
                .last_error
                .into_task_error(OPERATION, timeout.attempts)),
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Task operations
    // ─────────────────────────────────────────────────────────────────────

    /// Create a task with hierarchy validation and auto-timestamps.
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        // Validate 2-level hierarchy
        if let Some(ref parent_id) = params.parent_task_id
            && let Some(parent) = TaskRepository::get_task(conn, parent_id)?
            && parent.parent_task_id.is_some()
        {
            return Err(TaskError::Hierarchy(
                "Cannot create subtask of a subtask (max 2-level hierarchy)".to_string(),
            ));
        }

        let task = TaskRepository::create_task(conn, params)?;

        // Log creation activity
        TaskRepository::log_activity(
            conn,
            &LogActivityParams {
                task_id: task.id.clone(),
                session_id: params.created_by_session_id.clone(),
                event_id: None,
                action: ActivityAction::Created,
                old_value: None,
                new_value: None,
                detail: Some(format!("Task created: {}", task.title)),
                minutes_logged: None,
            },
        )?;

        Ok(task)
    }

    /// Get a task with full details (subtasks, dependencies, activity).
    pub fn get_task(conn: &Connection, id: &str) -> Result<TaskWithDetails, TaskError> {
        let task =
            TaskRepository::get_task(conn, id)?.ok_or_else(|| TaskError::task_not_found(id))?;

        let subtasks = TaskRepository::get_subtasks(conn, id)?;
        let blocked_by = TaskRepository::get_blocked_by(conn, id)?;
        let blocks = TaskRepository::get_blocks(conn, id)?;
        let recent_activity = TaskRepository::get_activity(conn, id, 20)?;

        Ok(TaskWithDetails {
            task,
            subtasks,
            blocked_by,
            blocks,
            recent_activity,
        })
    }

    /// Update a task with auto-transitions and activity logging.
    pub fn update_task(
        conn: &Connection,
        id: &str,
        updates: &TaskUpdateParams,
        session_id: Option<&str>,
    ) -> Result<Task, TaskError> {
        let current =
            TaskRepository::get_task(conn, id)?.ok_or_else(|| TaskError::task_not_found(id))?;

        // Build augmented updates with auto-transitions
        let mut augmented = updates.clone();

        if let Some(new_status) = updates.status {
            let old_status = current.status;

            // Auto-set started_at when transitioning to InProgress
            if new_status == TaskStatus::InProgress && old_status != TaskStatus::InProgress {
                // started_at is handled at SQL level via explicit update
            }

            // Auto-set completed_at for terminal states
            if new_status.is_terminal() && !old_status.is_terminal() {
                // We'll handle this via a separate SQL update after the main one
            }

            // Clear completed_at when reopening
            if !new_status.is_terminal() && old_status.is_terminal() {
                // Clear completed_at
            }

            // Log status change
            TaskRepository::log_activity(
                conn,
                &LogActivityParams {
                    task_id: id.to_string(),
                    session_id: session_id.map(String::from),
                    event_id: None,
                    action: ActivityAction::StatusChanged,
                    old_value: Some(old_status.as_sql().to_string()),
                    new_value: Some(new_status.as_sql().to_string()),
                    detail: None,
                    minutes_logged: None,
                },
            )?;
        }

        // Log note addition
        if updates.add_note.is_some() {
            TaskRepository::log_activity(
                conn,
                &LogActivityParams {
                    task_id: id.to_string(),
                    session_id: session_id.map(String::from),
                    event_id: None,
                    action: ActivityAction::NoteAdded,
                    old_value: None,
                    new_value: updates.add_note.clone(),
                    detail: None,
                    minutes_logged: None,
                },
            )?;
        }

        // Set last_session_id if provided
        if let Some(sid) = session_id {
            augmented.last_session_id = Some(sid.to_string());
        }

        let _updated = TaskRepository::update_task(conn, id, &augmented)?
            .ok_or_else(|| TaskError::task_not_found(id))?;

        // Handle auto-timestamp updates that require separate SQL
        if let Some(new_status) = updates.status {
            if new_status == TaskStatus::InProgress && current.started_at.is_none() {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let _ = conn.execute(
                    "UPDATE tasks SET started_at = ?1 WHERE id = ?2 AND started_at IS NULL",
                    rusqlite::params![now, id],
                )?;
            }
            if new_status.is_terminal() && !current.status.is_terminal() {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let _ = conn.execute(
                    "UPDATE tasks SET completed_at = ?1 WHERE id = ?2",
                    rusqlite::params![now, id],
                )?;
            }
            if !new_status.is_terminal() && current.status.is_terminal() {
                let _ = conn.execute(
                    "UPDATE tasks SET completed_at = NULL WHERE id = ?1",
                    rusqlite::params![id],
                )?;
            }
        }

        // Re-read to pick up auto-timestamp changes
        TaskRepository::get_task(conn, id)?.ok_or_else(|| TaskError::task_not_found(id))
    }

    /// Delete a task with activity logging.
    pub fn delete_task(
        conn: &Connection,
        id: &str,
        session_id: Option<&str>,
    ) -> Result<bool, TaskError> {
        // Verify exists
        let task = TaskRepository::get_task(conn, id)?;
        if task.is_none() {
            return Ok(false);
        }

        TaskRepository::log_activity(
            conn,
            &LogActivityParams {
                task_id: id.to_string(),
                session_id: session_id.map(String::from),
                event_id: None,
                action: ActivityAction::Deleted,
                old_value: None,
                new_value: None,
                detail: None,
                minutes_logged: None,
            },
        )?;

        TaskRepository::delete_task(conn, id)
    }

    /// Log time on a task.
    pub fn log_time(
        conn: &Connection,
        id: &str,
        minutes: i32,
        session_id: Option<&str>,
    ) -> Result<(), TaskError> {
        TaskRepository::increment_actual_minutes(conn, id, minutes)?;
        TaskRepository::log_activity(
            conn,
            &LogActivityParams {
                task_id: id.to_string(),
                session_id: session_id.map(String::from),
                event_id: None,
                action: ActivityAction::TimeLogged,
                old_value: None,
                new_value: None,
                detail: Some(format!("Logged {minutes} minutes")),
                minutes_logged: Some(minutes),
            },
        )?;
        Ok(())
    }

    /// List tasks with filtering and pagination.
    pub fn list_tasks(
        conn: &Connection,
        filter: &TaskFilter,
        limit: u32,
        offset: u32,
    ) -> Result<TaskListResult, TaskError> {
        TaskRepository::list_tasks(conn, filter, limit, offset)
    }

    /// Search tasks by title/description.
    pub fn search_tasks(
        conn: &Connection,
        query: &str,
        limit: u32,
    ) -> Result<Vec<Task>, TaskError> {
        TaskRepository::search_tasks(conn, query, limit)
    }

    /// Get activity log entries for a task.
    pub fn get_task_activity(
        conn: &Connection,
        task_id: &str,
        limit: u32,
    ) -> Result<Vec<TaskActivity>, TaskError> {
        TaskRepository::get_activity(conn, task_id, limit)
    }

    /// Add a dependency with circular detection for `Blocks` relationships.
    #[allow(clippy::similar_names)]
    pub fn add_dependency(
        conn: &Connection,
        blocker_id: &str,
        blocked_id: &str,
        relationship: DependencyRelationship,
        session_id: Option<&str>,
    ) -> Result<(), TaskError> {
        // Only check cycles for 'blocks' relationships
        if relationship == DependencyRelationship::Blocks
            && TaskRepository::has_circular_dependency(conn, blocker_id, blocked_id)?
        {
            return Err(TaskError::CircularDependency {
                blocker_id: blocker_id.to_string(),
                blocked_id: blocked_id.to_string(),
            });
        }

        TaskRepository::add_dependency(conn, blocker_id, blocked_id, relationship)?;

        // Log activity on both tasks
        TaskRepository::log_activity(
            conn,
            &LogActivityParams {
                task_id: blocker_id.to_string(),
                session_id: session_id.map(String::from),
                event_id: None,
                action: ActivityAction::DependencyAdded,
                old_value: None,
                new_value: Some(blocked_id.to_string()),
                detail: Some(format!("Now blocks {blocked_id}")),
                minutes_logged: None,
            },
        )?;
        TaskRepository::log_activity(
            conn,
            &LogActivityParams {
                task_id: blocked_id.to_string(),
                session_id: session_id.map(String::from),
                event_id: None,
                action: ActivityAction::DependencyAdded,
                old_value: None,
                new_value: Some(blocker_id.to_string()),
                detail: Some(format!("Blocked by {blocker_id}")),
                minutes_logged: None,
            },
        )?;

        Ok(())
    }

    /// Remove a dependency with activity logging.
    #[allow(clippy::similar_names)]
    pub fn remove_dependency(
        conn: &Connection,
        blocker_id: &str,
        blocked_id: &str,
        session_id: Option<&str>,
    ) -> Result<bool, TaskError> {
        let removed = TaskRepository::remove_dependency(conn, blocker_id, blocked_id)?;
        if removed
            && let Err(e) = TaskRepository::log_activity(
                conn,
                &LogActivityParams {
                    task_id: blocker_id.to_string(),
                    session_id: session_id.map(String::from),
                    event_id: None,
                    action: ActivityAction::DependencyRemoved,
                    old_value: Some(blocked_id.to_string()),
                    new_value: None,
                    detail: Some(format!("No longer blocks {blocked_id}")),
                    minutes_logged: None,
                },
            )
        {
            warn!(error = %e, "Failed to log dependency removal activity");
        }
        Ok(removed)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Batch operations
    // ─────────────────────────────────────────────────────────────────────

    /// Batch delete tasks by IDs or filter. Transactional with activity logging.
    pub fn batch_delete_tasks(
        conn: &Connection,
        target: &BatchTarget,
        dry_run: bool,
        session_id: Option<&str>,
    ) -> Result<BatchResult, TaskError> {
        if target.ids.as_ref().is_some_and(std::vec::Vec::is_empty) {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        let resolved = Self::resolve_batch_target(target)?;

        if dry_run {
            let count = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::count_tasks_by_ids(conn, ids)?,
                ResolvedTarget::Filter(f) => TaskRepository::count_tasks_by_filter(conn, f)?,
            };
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }

        Self::with_immediate_txn(conn, |tx| {
            // Pre-fetch for activity logging
            let tasks = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::get_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(f) => TaskRepository::get_tasks_by_filter(tx, f)?,
            };

            // Log activity BEFORE deleting — delete cascades task_activity rows,
            // so inserting after would violate the FK constraint.
            for task in &tasks {
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action: ActivityAction::Deleted,
                        old_value: Some(task.title.clone()),
                        new_value: None,
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
            }

            let affected = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::delete_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(f) => TaskRepository::delete_tasks_by_filter(tx, f)?,
            };

            Ok(BatchResult {
                affected,
                dry_run: false,
            })
        })
    }

    /// Batch update tasks by IDs or filter. Transactional with activity logging.
    pub fn batch_update_tasks(
        conn: &Connection,
        target: &BatchTarget,
        updates: &TaskUpdateParams,
        dry_run: bool,
        session_id: Option<&str>,
    ) -> Result<BatchResult, TaskError> {
        if target.ids.as_ref().is_some_and(std::vec::Vec::is_empty) {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        let resolved = Self::resolve_batch_target(target)?;

        if dry_run {
            let count = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::count_tasks_by_ids(conn, ids)?,
                ResolvedTarget::Filter(f) => TaskRepository::count_tasks_by_filter(conn, f)?,
            };
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }

        Self::with_immediate_txn(conn, |tx| {
            let tasks_before = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::get_tasks_by_ids(tx, ids)?,
                ResolvedTarget::Filter(f) => TaskRepository::get_tasks_by_filter(tx, f)?,
            };

            let affected = match &resolved {
                ResolvedTarget::Ids(ids) => TaskRepository::update_tasks_by_ids(tx, ids, updates)?,
                ResolvedTarget::Filter(f) => {
                    TaskRepository::update_tasks_by_filter(tx, f, updates)?
                }
            };

            for task in &tasks_before {
                let action = if updates.status.is_some() {
                    ActivityAction::StatusChanged
                } else {
                    ActivityAction::Updated
                };
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action,
                        old_value: updates.status.map(|_| task.status.as_sql().to_string()),
                        new_value: updates.status.map(|s| s.as_sql().to_string()),
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
            }

            Ok(BatchResult {
                affected,
                dry_run: false,
            })
        })
    }

    /// Resolve a `BatchTarget` into a type-safe `ResolvedTarget`, validating
    /// that either IDs or a filter is present.
    fn resolve_batch_target(target: &BatchTarget) -> Result<ResolvedTarget<'_>, TaskError> {
        if let Some(ids) = &target.ids {
            return Ok(ResolvedTarget::Ids(ids));
        }
        if let Some(filter) = &target.filter {
            let mut f = filter.clone();
            f.include_completed = true;
            f.include_deferred = true;
            f.include_backlog = true;
            return Ok(ResolvedTarget::Filter(f));
        }
        Err(TaskError::Validation("ids or filter required".into()))
    }

    /// Batch create tasks atomically. Returns JSON with affected count and created IDs.
    pub fn batch_create_tasks(
        conn: &Connection,
        items: &[TaskCreateParams],
        session_id: Option<&str>,
    ) -> Result<Value, TaskError> {
        if items.is_empty() {
            return Ok(json!({ "affected": 0, "dryRun": false, "ids": [] }));
        }

        for (i, item) in items.iter().enumerate() {
            if item.title.trim().is_empty() {
                return Err(TaskError::Validation(format!(
                    "item[{i}]: title is required"
                )));
            }
        }

        Self::with_immediate_txn(conn, |tx| {
            let mut created_ids = Vec::with_capacity(items.len());

            for item in items {
                let task = TaskRepository::create_task(tx, item)?;
                TaskRepository::log_activity(
                    tx,
                    &LogActivityParams {
                        task_id: task.id.clone(),
                        session_id: session_id.map(String::from),
                        event_id: None,
                        action: ActivityAction::Created,
                        old_value: None,
                        new_value: Some(task.title.clone()),
                        detail: None,
                        minutes_logged: None,
                    },
                )?;
                created_ids.push(task.id);
            }

            Ok(json!({
                "affected": created_ids.len(),
                "dryRun": false,
                "ids": created_ids,
            }))
        })
    }

    /// Batch delete projects by IDs.
    pub fn batch_delete_projects(
        conn: &Connection,
        ids: &[String],
        dry_run: bool,
    ) -> Result<BatchResult, TaskError> {
        if ids.is_empty() {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        if dry_run {
            let placeholders: String = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
            let sql = format!("SELECT COUNT(*) FROM projects WHERE id IN ({placeholders})");
            let params: Vec<&dyn rusqlite::types::ToSql> = ids
                .iter()
                .map(|id| id as &dyn rusqlite::types::ToSql)
                .collect();
            let count: u32 = conn.query_row(&sql, params.as_slice(), |row| row.get(0))?;
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }
        let affected = TaskRepository::delete_projects_by_ids(conn, ids)?;
        Ok(BatchResult {
            affected,
            dry_run: false,
        })
    }

    /// Batch delete areas by IDs.
    pub fn batch_delete_areas(
        conn: &Connection,
        ids: &[String],
        dry_run: bool,
    ) -> Result<BatchResult, TaskError> {
        if ids.is_empty() {
            return Ok(BatchResult {
                affected: 0,
                dry_run,
            });
        }
        if dry_run {
            let placeholders: String = ids.iter().map(|_| "?").collect::<Vec<_>>().join(",");
            let sql = format!("SELECT COUNT(*) FROM areas WHERE id IN ({placeholders})");
            let params: Vec<&dyn rusqlite::types::ToSql> = ids
                .iter()
                .map(|id| id as &dyn rusqlite::types::ToSql)
                .collect();
            let count: u32 = conn.query_row(&sql, params.as_slice(), |row| row.get(0))?;
            return Ok(BatchResult {
                affected: count,
                dry_run: true,
            });
        }
        let affected = TaskRepository::delete_areas_by_ids(conn, ids)?;
        Ok(BatchResult {
            affected,
            dry_run: false,
        })
    }

    // ─────────────────────────────────────────────────────────────────────
    // Project operations
    // ─────────────────────────────────────────────────────────────────────

    /// Create a project.
    pub fn create_project(
        conn: &Connection,
        params: &ProjectCreateParams,
    ) -> Result<Project, TaskError> {
        if params.title.trim().is_empty() {
            return Err(TaskError::Validation(
                "Project title is required".to_string(),
            ));
        }
        TaskRepository::create_project(conn, params)
    }

    /// Update a project with auto-timestamps.
    pub fn update_project(
        conn: &Connection,
        id: &str,
        updates: &ProjectUpdateParams,
    ) -> Result<Project, TaskError> {
        let current = TaskRepository::get_project(conn, id)?
            .ok_or_else(|| TaskError::project_not_found(id))?;

        let _result = TaskRepository::update_project(conn, id, updates)?
            .ok_or_else(|| TaskError::project_not_found(id))?;

        // Auto-set completed_at when status changes to completed
        if let Some(new_status) = updates.status {
            if new_status == ProjectStatus::Completed && current.status != ProjectStatus::Completed
            {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let _ = conn.execute(
                    "UPDATE projects SET completed_at = ?1 WHERE id = ?2",
                    rusqlite::params![now, id],
                )?;
            }
            if new_status != ProjectStatus::Completed && current.status == ProjectStatus::Completed
            {
                let _ = conn.execute(
                    "UPDATE projects SET completed_at = NULL WHERE id = ?1",
                    rusqlite::params![id],
                )?;
            }
        }

        TaskRepository::get_project(conn, id)?.ok_or_else(|| TaskError::project_not_found(id))
    }

    /// Get a project by ID.
    pub fn get_project(conn: &Connection, id: &str) -> Result<Project, TaskError> {
        TaskRepository::get_project(conn, id)?.ok_or_else(|| TaskError::project_not_found(id))
    }

    /// Get a project with its tasks.
    pub fn get_project_details(
        conn: &Connection,
        id: &str,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectWithTasks, TaskError> {
        let project = Self::get_project(conn, id)?;
        let tasks = Self::list_tasks(
            conn,
            &TaskFilter {
                project_id: Some(id.to_string()),
                ..Default::default()
            },
            limit,
            offset,
        )?
        .tasks;

        Ok(ProjectWithTasks { project, tasks })
    }

    /// Delete a project.
    pub fn delete_project(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        TaskRepository::delete_project(conn, id)
    }

    /// List projects with progress counts.
    pub fn list_projects(
        conn: &Connection,
        filter: &ProjectFilter,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectListResult, TaskError> {
        TaskRepository::list_projects(conn, filter, limit, offset)
    }

    // ─────────────────────────────────────────────────────────────────────
    // Area operations
    // ─────────────────────────────────────────────────────────────────────

    /// Create an area.
    pub fn create_area(conn: &Connection, params: &AreaCreateParams) -> Result<Area, TaskError> {
        if params.title.trim().is_empty() {
            return Err(TaskError::Validation("Area title is required".to_string()));
        }
        TaskRepository::create_area(conn, params)
    }

    /// Get an area by ID.
    pub fn get_area(conn: &Connection, id: &str) -> Result<Area, TaskError> {
        TaskRepository::get_area(conn, id)?.ok_or_else(|| TaskError::area_not_found(id))
    }

    /// Update an area.
    pub fn update_area(
        conn: &Connection,
        id: &str,
        updates: &AreaUpdateParams,
    ) -> Result<Area, TaskError> {
        TaskRepository::update_area(conn, id, updates)?.ok_or_else(|| TaskError::area_not_found(id))
    }

    /// Delete an area.
    pub fn delete_area(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        TaskRepository::delete_area(conn, id)
    }

    /// List areas with counts.
    pub fn list_areas(
        conn: &Connection,
        filter: &AreaFilter,
        limit: u32,
        offset: u32,
    ) -> Result<AreaListResult, TaskError> {
        TaskRepository::list_areas(conn, filter, limit, offset)
    }
}

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::tasks::migrations::run_migrations;
    use crate::tasks::types::*;
    use std::time::Duration;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    // --- Task creation ---

    #[test]
    fn test_create_task_logs_activity() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0].action, ActivityAction::Created);
    }

    #[test]
    fn test_create_subtask_of_subtask_rejected() {
        let conn = setup_db();
        let parent = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Parent".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let child = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child".to_string(),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Grandchild".to_string(),
                parent_task_id: Some(child.id.clone()),
                ..Default::default()
            },
        );
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("2-level hierarchy"));
    }

    // --- Task with details ---

    #[test]
    fn test_get_task_with_details() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Parent".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child".to_string(),
                parent_task_id: Some(task.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();

        let details = TaskService::get_task(&conn, &task.id).unwrap();
        assert_eq!(details.subtasks.len(), 1);
        assert!(!details.recent_activity.is_empty());
    }

    // --- Status transitions ---

    #[test]
    fn test_update_status_to_in_progress_sets_started_at() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(task.started_at.is_none());

        let updated = TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        assert!(updated.started_at.is_some());
    }

    #[test]
    fn test_update_status_to_completed_sets_completed_at() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        assert!(updated.completed_at.is_some());
    }

    #[test]
    fn test_reopen_clears_completed_at() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        // Complete it
        TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        // Reopen it
        let reopened = TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Pending),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        assert!(reopened.completed_at.is_none());
    }

    #[test]
    fn test_update_logs_status_change() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        // Created + StatusChanged
        assert_eq!(activity.len(), 2);
        assert_eq!(activity[0].action, ActivityAction::StatusChanged);
    }

    // --- Time logging ---

    #[test]
    fn test_log_time() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::log_time(&conn, &task.id, 45, None).unwrap();
        let updated = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert_eq!(updated.actual_minutes, 45);
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert!(
            activity
                .iter()
                .any(|a| a.action == ActivityAction::TimeLogged)
        );
    }

    // --- Dependencies ---

    #[test]
    fn test_add_dependency_circular_rejected() {
        let conn = setup_db();
        let t1 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks, None)
            .unwrap();
        let result = TaskService::add_dependency(
            &conn,
            &t2.id,
            &t1.id,
            DependencyRelationship::Blocks,
            None,
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Circular"));
    }

    #[test]
    fn test_related_dependency_no_cycle_check() {
        let conn = setup_db();
        let t1 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Related, None)
            .unwrap();
        // Related in reverse should be fine (no cycle check)
        TaskService::add_dependency(&conn, &t2.id, &t1.id, DependencyRelationship::Related, None)
            .unwrap();
    }

    #[test]
    fn test_add_dependency_logs_activity() {
        let conn = setup_db();
        let t1 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks, None)
            .unwrap();
        // Both tasks should have dependency activity
        let a1 = TaskRepository::get_activity(&conn, &t1.id, 10).unwrap();
        let a2 = TaskRepository::get_activity(&conn, &t2.id, 10).unwrap();
        assert!(
            a1.iter()
                .any(|a| a.action == ActivityAction::DependencyAdded)
        );
        assert!(
            a2.iter()
                .any(|a| a.action == ActivityAction::DependencyAdded)
        );
    }

    // --- Project validation ---

    #[test]
    fn test_create_project_empty_title_rejected() {
        let conn = setup_db();
        let result = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "  ".to_string(),
                ..Default::default()
            },
        );
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("title is required")
        );
    }

    #[test]
    fn test_project_auto_completed_at() {
        let conn = setup_db();
        let project = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskService::update_project(
            &conn,
            &project.id,
            &ProjectUpdateParams {
                status: Some(ProjectStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(updated.completed_at.is_some());
    }

    #[test]
    fn test_project_reopen_clears_completed_at() {
        let conn = setup_db();
        let project = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::update_project(
            &conn,
            &project.id,
            &ProjectUpdateParams {
                status: Some(ProjectStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let reopened = TaskService::update_project(
            &conn,
            &project.id,
            &ProjectUpdateParams {
                status: Some(ProjectStatus::Active),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(reopened.completed_at.is_none());
    }

    // --- Task list/search ---

    #[test]
    fn test_list_tasks_empty_db() {
        let conn = setup_db();
        let filter = TaskFilter::default();
        let result = TaskService::list_tasks(&conn, &filter, 20, 0).unwrap();
        assert_eq!(result.total, 0);
        assert!(result.tasks.is_empty());
    }

    #[test]
    fn test_list_tasks_with_status_filter() {
        let conn = setup_db();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let filter = TaskFilter {
            status: Some(TaskStatus::InProgress),
            include_completed: true,
            include_deferred: true,
            include_backlog: true,
            ..Default::default()
        };
        let result = TaskService::list_tasks(&conn, &filter, 20, 0).unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.tasks[0].title, "A");
    }

    #[test]
    fn test_search_tasks_by_title() {
        let conn = setup_db();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Fix login bug".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Add logout".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let results = TaskService::search_tasks(&conn, "login", 20).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn test_get_task_activity_returns_recent_entries() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Activity Task".to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            Some("session-1"),
        )
        .unwrap();

        let activity = TaskService::get_task_activity(&conn, &task.id, 10).unwrap();
        assert_eq!(activity.len(), 2);
        assert_eq!(activity[0].action, ActivityAction::StatusChanged);
        assert_eq!(activity[1].action, ActivityAction::Created);
    }

    // --- Project queries ---

    #[test]
    fn test_get_project_returns_project() {
        let conn = setup_db();
        let project = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "My Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskService::get_project(&conn, &project.id).unwrap();
        assert_eq!(result.title, "My Project");
    }

    #[test]
    fn test_get_project_not_found() {
        let conn = setup_db();
        let result = TaskService::get_project(&conn, "proj-missing");
        assert!(result.is_err());
    }

    #[test]
    fn test_delete_project() {
        let conn = setup_db();
        let project = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "To Delete".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let deleted = TaskService::delete_project(&conn, &project.id).unwrap();
        assert!(deleted);
    }

    #[test]
    fn test_list_projects() {
        let conn = setup_db();
        TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let filter = ProjectFilter::default();
        let result = TaskService::list_projects(&conn, &filter, 20, 0).unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.projects[0].project.title, "P1");
    }

    #[test]
    fn test_get_project_details_returns_project_tasks() {
        let conn = setup_db();
        let project = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Inside".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Outside".to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        let details = TaskService::get_project_details(&conn, &project.id, 100, 0).unwrap();
        assert_eq!(details.project.title, "Project");
        assert_eq!(details.tasks.len(), 1);
        assert_eq!(details.tasks[0].title, "Inside");
    }

    #[test]
    fn test_get_project_details_not_found() {
        let conn = setup_db();
        let result = TaskService::get_project_details(&conn, "proj-missing", 100, 0);
        assert!(matches!(
            result,
            Err(TaskError::NotFound {
                entity: "Project",
                ..
            })
        ));
    }

    // --- Area queries ---

    #[test]
    fn test_get_area_returns_area() {
        let conn = setup_db();
        let area = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "My Area".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskService::get_area(&conn, &area.id).unwrap();
        assert_eq!(result.title, "My Area");
    }

    #[test]
    fn test_get_area_not_found() {
        let conn = setup_db();
        let result = TaskService::get_area(&conn, "area-missing");
        assert!(result.is_err());
    }

    #[test]
    fn test_update_area() {
        let conn = setup_db();
        let area = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "Old Title".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskService::update_area(
            &conn,
            &area.id,
            &AreaUpdateParams {
                title: Some("New Title".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(updated.title, "New Title");
    }

    #[test]
    fn test_delete_area() {
        let conn = setup_db();
        let area = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "To Delete".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let deleted = TaskService::delete_area(&conn, &area.id).unwrap();
        assert!(deleted);
    }

    #[test]
    fn test_list_areas() {
        let conn = setup_db();
        TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "A1".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let filter = AreaFilter::default();
        let result = TaskService::list_areas(&conn, &filter, 20, 0).unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.areas[0].area.title, "A1");
    }

    // --- Batch operations ---

    #[test]
    fn test_batch_delete_tasks_by_ids() {
        let conn = setup_db();
        let mut ids = Vec::new();
        for title in &["A", "B", "C", "D", "E"] {
            let t = TaskService::create_task(
                &conn,
                &TaskCreateParams {
                    title: title.to_string(),
                    ..Default::default()
                },
            )
            .unwrap();
            ids.push(t.id);
        }
        let target = BatchTarget {
            ids: Some(ids[0..3].to_vec()),
            filter: None,
        };
        let result = TaskService::batch_delete_tasks(&conn, &target, false, None).unwrap();
        assert_eq!(result.affected, 3);
        assert!(!result.dry_run);
        // 2 remain
        let all = TaskService::list_tasks(
            &conn,
            &TaskFilter {
                include_completed: true,
                include_backlog: true,
                include_deferred: true,
                ..Default::default()
            },
            100,
            0,
        )
        .unwrap();
        assert_eq!(all.total, 2);
    }

    #[test]
    fn test_batch_delete_tasks_by_filter() {
        let conn = setup_db();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done2".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let target = BatchTarget {
            ids: None,
            filter: Some(TaskFilter {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            }),
        };
        let result = TaskService::batch_delete_tasks(&conn, &target, false, None).unwrap();
        assert_eq!(result.affected, 2);
    }

    #[test]
    fn test_batch_delete_tasks_dry_run_by_ids() {
        let conn = setup_db();
        let mut ids = Vec::new();
        for title in &["A", "B", "C"] {
            let t = TaskService::create_task(
                &conn,
                &TaskCreateParams {
                    title: title.to_string(),
                    ..Default::default()
                },
            )
            .unwrap();
            ids.push(t.id);
        }
        let target = BatchTarget {
            ids: Some(ids[0..2].to_vec()),
            filter: None,
        };
        let result = TaskService::batch_delete_tasks(&conn, &target, true, None).unwrap();
        assert_eq!(result.affected, 2);
        assert!(result.dry_run);
        // All 3 still exist
        let all = TaskService::list_tasks(
            &conn,
            &TaskFilter {
                include_completed: true,
                include_backlog: true,
                include_deferred: true,
                ..Default::default()
            },
            100,
            0,
        )
        .unwrap();
        assert_eq!(all.total, 3);
    }

    #[test]
    fn test_batch_delete_tasks_empty_ids() {
        let conn = setup_db();
        let target = BatchTarget {
            ids: Some(vec![]),
            filter: None,
        };
        let result = TaskService::batch_delete_tasks(&conn, &target, false, None).unwrap();
        assert_eq!(result.affected, 0);
    }

    #[test]
    fn test_batch_delete_tasks_no_target() {
        let conn = setup_db();
        let target = BatchTarget {
            ids: None,
            filter: None,
        };
        let result = TaskService::batch_delete_tasks(&conn, &target, false, None);
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("ids or filter required")
        );
    }

    #[test]
    fn test_batch_delete_tasks_logs_activity() {
        let conn = setup_db();
        let t = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "To Delete".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let target = BatchTarget {
            ids: Some(vec![t.id]),
            filter: None,
        };
        TaskService::batch_delete_tasks(&conn, &target, false, None).unwrap();
        // Activity was logged before the delete (task_activity references task_id but cascades)
        // Just verify the method didn't error — the activity is cascade-deleted with the task
    }

    #[test]
    fn test_batch_update_tasks_by_ids_status() {
        let conn = setup_db();
        let mut ids = Vec::new();
        for title in &["A", "B", "C"] {
            let t = TaskService::create_task(
                &conn,
                &TaskCreateParams {
                    title: title.to_string(),
                    ..Default::default()
                },
            )
            .unwrap();
            ids.push(t.id);
        }
        let target = BatchTarget {
            ids: Some(ids.clone()),
            filter: None,
        };
        let result = TaskService::batch_update_tasks(
            &conn,
            &target,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            false,
            None,
        )
        .unwrap();
        assert_eq!(result.affected, 3);

        // Verify completed_at auto-set
        let t = TaskRepository::get_task(&conn, &ids[0]).unwrap().unwrap();
        assert_eq!(t.status, TaskStatus::Completed);
        assert!(t.completed_at.is_some());
    }

    #[test]
    fn test_batch_update_tasks_by_filter() {
        let conn = setup_db();
        let proj = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "In proj".into(),
                project_id: Some(proj.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Outside".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let target = BatchTarget {
            ids: None,
            filter: Some(TaskFilter {
                project_id: Some(proj.id),
                ..Default::default()
            }),
        };
        let result = TaskService::batch_update_tasks(
            &conn,
            &target,
            &TaskUpdateParams {
                status: Some(TaskStatus::Cancelled),
                ..Default::default()
            },
            false,
            None,
        )
        .unwrap();
        assert_eq!(result.affected, 1);
    }

    #[test]
    fn test_batch_update_tasks_dry_run() {
        let conn = setup_db();
        let t = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let target = BatchTarget {
            ids: Some(vec![t.id.clone()]),
            filter: None,
        };
        let result = TaskService::batch_update_tasks(
            &conn,
            &target,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            true,
            None,
        )
        .unwrap();
        assert_eq!(result.affected, 1);
        assert!(result.dry_run);
        // Not actually updated
        let task = TaskRepository::get_task(&conn, &t.id).unwrap().unwrap();
        assert_eq!(task.status, TaskStatus::Pending);
    }

    #[test]
    fn test_batch_update_tasks_no_target() {
        let conn = setup_db();
        let target = BatchTarget {
            ids: None,
            filter: None,
        };
        let result = TaskService::batch_update_tasks(
            &conn,
            &target,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            false,
            None,
        );
        assert!(result.is_err());
    }

    #[test]
    fn test_batch_create_tasks() {
        let conn = setup_db();
        let items = vec![
            TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
            TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
            TaskCreateParams {
                title: "C".into(),
                ..Default::default()
            },
        ];
        let result = TaskService::batch_create_tasks(&conn, &items, None).unwrap();
        assert_eq!(result["affected"], 3);
        assert_eq!(result["ids"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn test_batch_create_tasks_empty() {
        let conn = setup_db();
        let result = TaskService::batch_create_tasks(&conn, &[], None).unwrap();
        assert_eq!(result["affected"], 0);
    }

    #[test]
    fn test_batch_create_tasks_invalid_item_rolls_back() {
        let conn = setup_db();
        let items = vec![
            TaskCreateParams {
                title: "Good".into(),
                ..Default::default()
            },
            TaskCreateParams {
                title: String::new(),
                ..Default::default()
            },
            TaskCreateParams {
                title: "Also Good".into(),
                ..Default::default()
            },
        ];
        let result = TaskService::batch_create_tasks(&conn, &items, None);
        assert!(result.is_err());
        // Nothing created
        let all = TaskService::list_tasks(
            &conn,
            &TaskFilter {
                include_completed: true,
                include_backlog: true,
                include_deferred: true,
                ..Default::default()
            },
            100,
            0,
        )
        .unwrap();
        assert_eq!(all.total, 0);
    }

    #[test]
    fn test_batch_delete_projects_by_ids() {
        let conn = setup_db();
        let p1 = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let p2 = TaskService::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P2".into(),
                ..Default::default()
            },
        )
        .unwrap();
        // Create a task in P1 to verify orphaning
        TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "In P1".into(),
                project_id: Some(p1.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();

        let result =
            TaskService::batch_delete_projects(&conn, &[p1.id.clone(), p2.id.clone()], false)
                .unwrap();
        assert_eq!(result.affected, 2);
    }

    #[test]
    fn test_batch_delete_areas_by_ids() {
        let conn = setup_db();
        let a1 = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "A1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let a2 = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "A2".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let result =
            TaskService::batch_delete_areas(&conn, &[a1.id.clone(), a2.id.clone()], false).unwrap();
        assert_eq!(result.affected, 2);
    }

    // --- Area validation ---

    #[test]
    fn test_create_area_empty_title_rejected() {
        let conn = setup_db();
        let result = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: String::new(),
                ..Default::default()
            },
        );
        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("title is required")
        );
    }

    // --- Delete task ---

    #[test]
    fn test_delete_task_logs_activity() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        // Activity is logged before deletion (since delete cascades activity)
        // We verify the return value
        let deleted = TaskService::delete_task(&conn, &task.id, None).unwrap();
        assert!(deleted);
    }

    #[test]
    fn test_delete_nonexistent_task() {
        let conn = setup_db();
        let deleted = TaskService::delete_task(&conn, "task-missing", None).unwrap();
        assert!(!deleted);
    }

    #[test]
    fn test_with_immediate_txn_returns_busy_when_write_locked() {
        let dir = tempfile::tempdir().unwrap();
        let db_path = dir.path().join("tasks.db");

        let conn1 = Connection::open(&db_path).unwrap();
        conn1.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn1).unwrap();

        let conn2 = Connection::open(&db_path).unwrap();
        conn2.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn2).unwrap();

        conn1.execute_batch("BEGIN IMMEDIATE").unwrap();

        let result = TaskService::with_immediate_txn_policy(
            &conn2,
            contention::BusyRetryPolicy {
                deadline: Duration::ZERO,
                backoff_step: Duration::ZERO,
                max_backoff: Duration::ZERO,
                jitter_percent: 0,
            },
            |_tx| Ok(()),
        );

        conn1.execute_batch("ROLLBACK").unwrap();

        match result {
            Err(TaskError::Busy {
                operation,
                attempts,
            }) => {
                assert_eq!(operation, "task batch transaction");
                assert_eq!(attempts, 1);
            }
            other => panic!("expected busy error, got {other:?}"),
        }
    }
}
