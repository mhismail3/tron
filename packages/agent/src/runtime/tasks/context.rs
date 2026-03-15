//! Task context builder for LLM system prompt injection.
//!
//! Generates a concise summary of active tasks that gets injected into the
//! system prompt. Returns `None` if there are no open tasks.

use std::fmt::Write;

use rusqlite::Connection;

use super::errors::TaskError;
use super::repository::TaskRepository;

/// Build a summary of active tasks for LLM context injection.
///
/// Returns `None` if there are no active tasks.
///
/// # Output format
///
/// ```text
/// Tasks: 2 in progress, 5 pending, 1 stale
/// In Progress:
///   - [task-abc] Fix authentication bug
///   - [task-xyz] Add dark mode support
/// Stale (from previous sessions — resume or close):
///   - [task-def] Refactor logging
/// ```
pub fn build_task_context(conn: &Connection) -> Result<Option<String>, TaskError> {
    let summary = TaskRepository::get_active_task_summary(conn)?;

    // Nothing to report
    if summary.in_progress.is_empty()
        && summary.pending_count == 0
        && summary.stale_count == 0
    {
        return Ok(None);
    }

    let mut output = String::new();

    // Summary line
    let _ = write!(
        output,
        "Tasks: {} in progress, {} pending",
        summary.in_progress.len(),
        summary.pending_count,
    );
    if summary.stale_count > 0 {
        let _ = write!(output, ", {} stale", summary.stale_count);
    }

    // In-progress tasks
    if !summary.in_progress.is_empty() {
        let _ = write!(output, "\nIn Progress:");
        for task in &summary.in_progress {
            let _ = write!(output, "\n  - [{}] {}", task.id, task.title);
        }
    }

    // Stale tasks
    if !summary.stale_tasks.is_empty() {
        let _ = write!(
            output,
            "\nStale (from previous sessions — resume or close):"
        );
        for task in &summary.stale_tasks {
            let _ = write!(output, "\n  - [{}] {}", task.id, task.title);
        }
    }

    Ok(Some(output))
}

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::runtime::tasks::migrations::run_migrations;
    use crate::runtime::tasks::types::*;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn test_empty_returns_none() {
        let conn = setup_db();
        let result = build_task_context(&conn).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_single_in_progress_task() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Fix bug".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn).unwrap().unwrap();
        assert!(result.contains("1 in progress"));
        assert!(result.contains("Fix bug"));
    }

    #[test]
    fn test_stale_tasks_shown() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Stale task".to_string(),
                status: Some(TaskStatus::Stale),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn).unwrap().unwrap();
        assert!(result.contains("1 stale"));
        assert!(result.contains("Stale task"));
        assert!(result.contains("resume or close"));
    }

    #[test]
    fn test_mixed_statuses() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "In progress".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Pending task".to_string(),
                status: Some(TaskStatus::Pending),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Stale task".to_string(),
                status: Some(TaskStatus::Stale),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn).unwrap().unwrap();
        assert!(result.contains("1 in progress"));
        assert!(result.contains("1 pending"));
        assert!(result.contains("1 stale"));
    }

    #[test]
    fn test_completed_not_shown() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done task".to_string(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_subtasks_not_separate() {
        let conn = setup_db();
        let parent = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Parent".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Subtask".to_string(),
                status: Some(TaskStatus::InProgress),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let result = build_task_context(&conn).unwrap().unwrap();
        // Both show up because they're both in_progress — but that's fine,
        // the context just lists all in_progress tasks
        assert!(result.contains("2 in progress"));
    }
}
