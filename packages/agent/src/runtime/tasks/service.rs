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
//! - **Stale marking**: Session end marks in-progress tasks as stale.

use super::errors::TaskError;
use super::repository::TaskRepository;
use super::types::{
    ActivityAction, LogActivityParams, Task, TaskActivity, TaskCreateParams, TaskFilter,
    TaskListResult, TaskStatus, TaskUpdateParams, TaskWithDetails,
};

mod task_ops;

/// Task service with business logic and validation.
pub struct TaskService;

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use crate::runtime::tasks::migrations::run_migrations;
    use crate::runtime::tasks::types::*;

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
    fn test_create_task_empty_title_rejected() {
        let conn = setup_db();
        let result = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "  ".to_string(),
                ..Default::default()
            },
        );
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("title is required"));
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
    fn test_stale_to_in_progress() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                status: Some(TaskStatus::InProgress),
                created_by_session_id: Some("s1".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        // Mark stale
        TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Stale),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        // Resume
        let resumed = TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        assert!(resumed.completed_at.is_none());
        assert!(resumed.started_at.is_some());
    }

    #[test]
    fn test_stale_to_completed() {
        let conn = setup_db();
        let task = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Stale),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        let completed = TaskService::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            None,
        )
        .unwrap();
        assert!(completed.completed_at.is_some());
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
        let deleted = TaskService::delete_task(&conn, &task.id, None).unwrap();
        assert!(deleted);
    }

    #[test]
    fn test_delete_nonexistent_task() {
        let conn = setup_db();
        let deleted = TaskService::delete_task(&conn, "task-missing", None).unwrap();
        assert!(!deleted);
    }

    // --- Stale marking ---

    #[test]
    fn test_mark_session_tasks_stale() {
        let conn = setup_db();
        let t1 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "In Progress 1".to_string(),
                status: Some(TaskStatus::InProgress),
                created_by_session_id: Some("s1".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        // Update to set last_session_id
        TaskService::update_task(
            &conn,
            &t1.id,
            &TaskUpdateParams {
                title: Some("Updated".to_string()),
                ..Default::default()
            },
            Some("s1"),
        )
        .unwrap();

        let t2 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Completed".to_string(),
                status: Some(TaskStatus::Completed),
                created_by_session_id: Some("s1".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        let count = TaskService::mark_session_tasks_stale(&conn, "s1").unwrap();
        assert_eq!(count, 1);

        let updated = TaskRepository::get_task(&conn, &t1.id).unwrap().unwrap();
        assert_eq!(updated.status, TaskStatus::Stale);

        // Completed task should be unchanged
        let completed = TaskRepository::get_task(&conn, &t2.id).unwrap().unwrap();
        assert_eq!(completed.status, TaskStatus::Completed);
    }

    #[test]
    fn test_mark_stale_no_matching_tasks() {
        let conn = setup_db();
        let count = TaskService::mark_session_tasks_stale(&conn, "nonexistent").unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_mark_stale_different_session() {
        let conn = setup_db();
        let t1 = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "Session 2 task".to_string(),
                status: Some(TaskStatus::InProgress),
                created_by_session_id: Some("s2".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskService::update_task(
            &conn,
            &t1.id,
            &TaskUpdateParams {
                title: Some("Updated".to_string()),
                ..Default::default()
            },
            Some("s2"),
        )
        .unwrap();

        // Mark stale for s1 — should not affect s2's task
        let count = TaskService::mark_session_tasks_stale(&conn, "s1").unwrap();
        assert_eq!(count, 0);

        let task = TaskRepository::get_task(&conn, &t1.id).unwrap().unwrap();
        assert_eq!(task.status, TaskStatus::InProgress);
    }

    // --- Batch create ---

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
                ..Default::default()
            },
            100,
            0,
        )
        .unwrap();
        assert_eq!(all.total, 0);
    }

}
