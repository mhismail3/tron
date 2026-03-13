use rusqlite::Connection;
use tracing::warn;

use super::{
    ActivityAction, DependencyRelationship, LogActivityParams, Task, TaskActivity,
    TaskCreateParams, TaskError, TaskFilter, TaskListResult, TaskRepository, TaskService,
    TaskStatus, TaskUpdateParams, TaskWithDetails,
};

impl TaskService {
    /// Create a task with hierarchy validation and auto-timestamps.
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        if let Some(ref parent_id) = params.parent_task_id
            && let Some(parent) = TaskRepository::get_task(conn, parent_id)?
            && parent.parent_task_id.is_some()
        {
            return Err(TaskError::Hierarchy(
                "Cannot create subtask of a subtask (max 2-level hierarchy)".to_string(),
            ));
        }

        let task = TaskRepository::create_task(conn, params)?;

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

        let mut augmented = updates.clone();

        if let Some(new_status) = updates.status {
            let old_status = current.status;

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

        if let Some(sid) = session_id {
            augmented.last_session_id = Some(sid.to_string());
        }

        let _updated = TaskRepository::update_task(conn, id, &augmented)?
            .ok_or_else(|| TaskError::task_not_found(id))?;

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

        TaskRepository::get_task(conn, id)?.ok_or_else(|| TaskError::task_not_found(id))
    }

    /// Delete a task with activity logging.
    pub fn delete_task(
        conn: &Connection,
        id: &str,
        session_id: Option<&str>,
    ) -> Result<bool, TaskError> {
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
        if relationship == DependencyRelationship::Blocks
            && TaskRepository::has_circular_dependency(conn, blocker_id, blocked_id)?
        {
            return Err(TaskError::CircularDependency {
                blocker_id: blocker_id.to_string(),
                blocked_id: blocked_id.to_string(),
            });
        }

        TaskRepository::add_dependency(conn, blocker_id, blocked_id, relationship)?;

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
            && let Err(error) = TaskRepository::log_activity(
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
            warn!(error = %error, "Failed to log dependency removal activity");
        }
        Ok(removed)
    }
}
