use rusqlite::Connection;
use serde_json::{Value, json};
use tracing::warn;

use super::{
    ActivityAction, LogActivityParams, Task, TaskActivity, TaskCreateParams, TaskError,
    TaskFilter, TaskListResult, TaskRepository, TaskService, TaskStatus, TaskUpdateParams,
    TaskWithDetails,
};

impl TaskService {
    /// Create a task with hierarchy validation and auto-timestamps.
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        if params.title.trim().is_empty() {
            return Err(TaskError::Validation("title is required".to_string()));
        }

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
            },
        )?;

        Ok(task)
    }

    /// Get a task with full details (subtasks, activity).
    pub fn get_task(conn: &Connection, id: &str) -> Result<TaskWithDetails, TaskError> {
        let task =
            TaskRepository::get_task(conn, id)?.ok_or_else(|| TaskError::task_not_found(id))?;

        let subtasks = TaskRepository::get_subtasks(conn, id)?;
        let recent_activity = TaskRepository::get_activity(conn, id, 20)?;

        Ok(TaskWithDetails {
            task,
            subtasks,
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

            // Skip no-op status changes
            if new_status != old_status {
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
                    },
                )?;
            }
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
            // Stale -> InProgress: clear completed_at, set started_at
            if new_status == TaskStatus::InProgress && current.status == TaskStatus::Stale {
                let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
                let _ = conn.execute(
                    "UPDATE tasks SET completed_at = NULL, started_at = COALESCE(started_at, ?1) WHERE id = ?2",
                    rusqlite::params![now, id],
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
            },
        )?;

        TaskRepository::delete_task(conn, id)
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

    /// Mark all in-progress tasks for a session as stale.
    pub fn mark_session_tasks_stale(
        conn: &Connection,
        session_id: &str,
    ) -> Result<usize, TaskError> {
        // Get tasks that will be marked stale for activity logging
        let filter = TaskFilter {
            status: Some(TaskStatus::InProgress),
            ..Default::default()
        };
        let in_progress = TaskRepository::list_tasks(conn, &filter, 1000, 0)?;
        let affected_tasks: Vec<_> = in_progress
            .tasks
            .iter()
            .filter(|t| t.last_session_id.as_deref() == Some(session_id))
            .collect();

        let count = TaskRepository::mark_stale_tasks(conn, session_id)?;

        // Log activity for each affected task
        for task in &affected_tasks {
            if let Err(e) = TaskRepository::log_activity(
                conn,
                &LogActivityParams {
                    task_id: task.id.clone(),
                    session_id: Some(session_id.to_string()),
                    event_id: None,
                    action: ActivityAction::StatusChanged,
                    old_value: Some("in_progress".to_string()),
                    new_value: Some("stale".to_string()),
                    detail: Some("Session ended — task marked stale".to_string()),
                },
            ) {
                warn!(task_id = %task.id, error = %e, "failed to log stale activity");
            }
        }

        Ok(count)
    }

    /// Batch create tasks atomically.
    pub fn batch_create_tasks(
        conn: &Connection,
        items: &[TaskCreateParams],
        _session_id: Option<&str>,
    ) -> Result<Value, TaskError> {
        if items.is_empty() {
            return Ok(json!({"affected": 0, "ids": []}));
        }

        conn.execute_batch("BEGIN IMMEDIATE")?;

        let mut ids = Vec::new();
        for item in items {
            match Self::create_task(conn, item) {
                Ok(task) => ids.push(task.id),
                Err(e) => {
                    let _ = conn.execute_batch("ROLLBACK");
                    return Err(e);
                }
            }
        }

        conn.execute_batch("COMMIT")?;

        Ok(json!({
            "affected": ids.len(),
            "ids": ids,
        }))
    }
}
