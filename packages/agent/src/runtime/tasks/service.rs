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

use super::errors::TaskError;
use super::repository::TaskRepository;
use super::types::{
    ActivityAction, Area, AreaCreateParams, AreaFilter, AreaListResult, AreaUpdateParams,
    BatchResult, BatchTarget, DependencyRelationship, LogActivityParams, Project,
    ProjectCreateParams, ProjectFilter, ProjectListResult, ProjectStatus, ProjectUpdateParams,
    ProjectWithTasks, Task, TaskActivity, TaskCreateParams, TaskFilter, TaskListResult, TaskStatus,
    TaskUpdateParams, TaskWithDetails,
};

mod area_ops;
mod batch_ops;
mod project_ops;
mod task_ops;
mod transaction;

#[cfg(test)]
use rusqlite::Connection;
#[cfg(test)]
use crate::events::sqlite::contention;

/// Task service with business logic and validation.
pub struct TaskService;

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::runtime::tasks::migrations::run_migrations;
    use crate::runtime::tasks::types::*;
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
    fn test_batch_update_tasks_sets_completed_at() {
        let conn = setup_db();
        let first = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let second = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let result = TaskService::batch_update_tasks(
            &conn,
            &BatchTarget {
                ids: Some(vec![first.id.clone(), second.id.clone()]),
                filter: None,
            },
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
            false,
            None,
        )
        .unwrap();

        assert_eq!(result.affected, 2);

        let first = TaskRepository::get_task(&conn, &first.id).unwrap().unwrap();
        let second = TaskRepository::get_task(&conn, &second.id)
            .unwrap()
            .unwrap();
        assert!(first.completed_at.is_some());
        assert!(second.completed_at.is_some());
    }

    #[test]
    fn test_batch_update_tasks_reopen_clears_completed_at() {
        let conn = setup_db();
        let first = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let second = TaskService::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();

        let result = TaskService::batch_update_tasks(
            &conn,
            &BatchTarget {
                ids: Some(vec![first.id.clone(), second.id.clone()]),
                filter: None,
            },
            &TaskUpdateParams {
                status: Some(TaskStatus::Pending),
                ..Default::default()
            },
            false,
            None,
        )
        .unwrap();

        assert_eq!(result.affected, 2);

        let first = TaskRepository::get_task(&conn, &first.id).unwrap().unwrap();
        let second = TaskRepository::get_task(&conn, &second.id)
            .unwrap()
            .unwrap();
        assert!(first.completed_at.is_none());
        assert!(second.completed_at.is_none());
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
