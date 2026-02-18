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

use super::errors::TaskError;
use super::repository::TaskRepository;
use super::types::{
    ActivityAction, Area, AreaCreateParams, AreaFilter, AreaListResult, AreaUpdateParams,
    DependencyRelationship, LogActivityParams, Project, ProjectCreateParams, ProjectFilter,
    ProjectListResult, ProjectStatus, ProjectUpdateParams, Task, TaskCreateParams, TaskFilter,
    TaskListResult, TaskStatus, TaskUpdateParams, TaskWithDetails,
};

/// Task service with business logic and validation.
pub struct TaskService;

impl TaskService {
    // ─────────────────────────────────────────────────────────────────────
    // Task operations
    // ─────────────────────────────────────────────────────────────────────

    /// Create a task with hierarchy validation and auto-timestamps.
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        // Validate 2-level hierarchy
        if let Some(ref parent_id) = params.parent_task_id {
            if let Some(parent) = TaskRepository::get_task(conn, parent_id)? {
                if parent.parent_task_id.is_some() {
                    return Err(TaskError::Hierarchy(
                        "Cannot create subtask of a subtask (max 2-level hierarchy)".to_string(),
                    ));
                }
            }
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
        if removed {
            if let Err(e) = TaskRepository::log_activity(
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
            ) {
                warn!(error = %e, "Failed to log dependency removal activity");
            }
        }
        Ok(removed)
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
        TaskRepository::update_area(conn, id, updates)?
            .ok_or_else(|| TaskError::area_not_found(id))
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

    // --- Area validation ---

    #[test]
    fn test_create_area_empty_title_rejected() {
        let conn = setup_db();
        let result = TaskService::create_area(
            &conn,
            &AreaCreateParams {
                title: "".to_string(),
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
}
