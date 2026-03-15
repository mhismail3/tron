//! SQL data access layer for tasks, projects, and areas.
//!
//! All methods take a `&Connection` parameter and are stateless — pure functions
//! that translate between Rust types and SQL. Uses `uuid::Uuid::now_v7()` for
//! time-ordered ID generation with entity-specific prefixes.

mod activity;
mod areas;
mod batch;
mod common;
mod dependencies;
mod projects;
mod summary;
mod tasks;

use rusqlite::Connection;

use super::errors::TaskError;
use super::types::{
    ActiveTaskSummary, Area, AreaCreateParams, AreaFilter, AreaListResult, AreaUpdateParams,
    DependencyRelationship, LogActivityParams, Project, ProjectCreateParams, ProjectFilter,
    ProjectListResult, ProjectProgressEntry, ProjectUpdateParams, Task, TaskActivity,
    TaskCreateParams, TaskDependency, TaskFilter, TaskListResult, TaskUpdateParams,
};

/// Task repository for SQL CRUD operations.
pub struct TaskRepository;

impl TaskRepository {
    pub fn create_task(conn: &Connection, params: &TaskCreateParams) -> Result<Task, TaskError> {
        tasks::create_task(conn, params)
    }

    pub fn get_task(conn: &Connection, id: &str) -> Result<Option<Task>, TaskError> {
        tasks::get_task(conn, id)
    }

    pub fn update_task(
        conn: &Connection,
        id: &str,
        updates: &TaskUpdateParams,
    ) -> Result<Option<Task>, TaskError> {
        tasks::update_task(conn, id, updates)
    }

    pub fn delete_task(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        tasks::delete_task(conn, id)
    }

    pub fn increment_actual_minutes(
        conn: &Connection,
        id: &str,
        minutes: i32,
    ) -> Result<(), TaskError> {
        tasks::increment_actual_minutes(conn, id, minutes)
    }

    pub fn list_tasks(
        conn: &Connection,
        filter: &TaskFilter,
        limit: u32,
        offset: u32,
    ) -> Result<TaskListResult, TaskError> {
        tasks::list_tasks(conn, filter, limit, offset)
    }

    pub fn get_subtasks(conn: &Connection, parent_task_id: &str) -> Result<Vec<Task>, TaskError> {
        tasks::get_subtasks(conn, parent_task_id)
    }

    pub fn search_tasks(
        conn: &Connection,
        query: &str,
        limit: u32,
    ) -> Result<Vec<Task>, TaskError> {
        tasks::search_tasks(conn, query, limit)
    }

    pub fn create_project(
        conn: &Connection,
        params: &ProjectCreateParams,
    ) -> Result<Project, TaskError> {
        projects::create_project(conn, params)
    }

    pub fn get_project(conn: &Connection, id: &str) -> Result<Option<Project>, TaskError> {
        projects::get_project(conn, id)
    }

    pub fn update_project(
        conn: &Connection,
        id: &str,
        updates: &ProjectUpdateParams,
    ) -> Result<Option<Project>, TaskError> {
        projects::update_project(conn, id, updates)
    }

    pub fn delete_project(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        projects::delete_project(conn, id)
    }

    pub fn list_projects(
        conn: &Connection,
        filter: &ProjectFilter,
        limit: u32,
        offset: u32,
    ) -> Result<ProjectListResult, TaskError> {
        projects::list_projects(conn, filter, limit, offset)
    }

    pub fn create_area(conn: &Connection, params: &AreaCreateParams) -> Result<Area, TaskError> {
        areas::create_area(conn, params)
    }

    pub fn get_area(conn: &Connection, id: &str) -> Result<Option<Area>, TaskError> {
        areas::get_area(conn, id)
    }

    pub fn update_area(
        conn: &Connection,
        id: &str,
        updates: &AreaUpdateParams,
    ) -> Result<Option<Area>, TaskError> {
        areas::update_area(conn, id, updates)
    }

    pub fn delete_area(conn: &Connection, id: &str) -> Result<bool, TaskError> {
        areas::delete_area(conn, id)
    }

    pub fn list_areas(
        conn: &Connection,
        filter: &AreaFilter,
        limit: u32,
        offset: u32,
    ) -> Result<AreaListResult, TaskError> {
        areas::list_areas(conn, filter, limit, offset)
    }

    pub fn add_dependency(
        conn: &Connection,
        blocking_task_id: &str,
        waiting_task_id: &str,
        relationship: DependencyRelationship,
    ) -> Result<(), TaskError> {
        dependencies::add_dependency(conn, blocking_task_id, waiting_task_id, relationship)
    }

    pub fn remove_dependency(
        conn: &Connection,
        blocking_task_id: &str,
        waiting_task_id: &str,
    ) -> Result<bool, TaskError> {
        dependencies::remove_dependency(conn, blocking_task_id, waiting_task_id)
    }

    pub fn get_blocked_by(
        conn: &Connection,
        task_id: &str,
    ) -> Result<Vec<TaskDependency>, TaskError> {
        dependencies::get_blocked_by(conn, task_id)
    }

    pub fn get_blocks(conn: &Connection, task_id: &str) -> Result<Vec<TaskDependency>, TaskError> {
        dependencies::get_blocks(conn, task_id)
    }

    pub fn has_circular_dependency(
        conn: &Connection,
        upstream_task_id: &str,
        downstream_task_id: &str,
    ) -> Result<bool, TaskError> {
        dependencies::has_circular_dependency(conn, upstream_task_id, downstream_task_id)
    }

    pub fn get_blocked_task_count(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<u32, TaskError> {
        dependencies::get_blocked_task_count(conn, workspace_id)
    }

    pub fn log_activity(conn: &Connection, params: &LogActivityParams) -> Result<(), TaskError> {
        activity::log_activity(conn, params)
    }

    pub fn get_activity(
        conn: &Connection,
        task_id: &str,
        limit: u32,
    ) -> Result<Vec<TaskActivity>, TaskError> {
        activity::get_activity(conn, task_id, limit)
    }

    pub fn delete_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
        batch::delete_tasks_by_ids(conn, ids)
    }

    pub fn delete_tasks_by_filter(
        conn: &Connection,
        filter: &TaskFilter,
    ) -> Result<u32, TaskError> {
        batch::delete_tasks_by_filter(conn, filter)
    }

    pub fn count_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
        batch::count_tasks_by_ids(conn, ids)
    }

    pub fn count_tasks_by_filter(conn: &Connection, filter: &TaskFilter) -> Result<u32, TaskError> {
        batch::count_tasks_by_filter(conn, filter)
    }

    pub fn get_tasks_by_ids(conn: &Connection, ids: &[String]) -> Result<Vec<Task>, TaskError> {
        batch::get_tasks_by_ids(conn, ids)
    }

    pub fn get_tasks_by_filter(
        conn: &Connection,
        filter: &TaskFilter,
    ) -> Result<Vec<Task>, TaskError> {
        batch::get_tasks_by_filter(conn, filter)
    }

    pub fn update_tasks_by_ids(
        conn: &Connection,
        ids: &[String],
        updates: &TaskUpdateParams,
    ) -> Result<u32, TaskError> {
        batch::update_tasks_by_ids(conn, ids, updates)
    }

    pub fn update_tasks_by_filter(
        conn: &Connection,
        filter: &TaskFilter,
        updates: &TaskUpdateParams,
    ) -> Result<u32, TaskError> {
        batch::update_tasks_by_filter(conn, filter, updates)
    }

    pub fn delete_projects_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
        batch::delete_projects_by_ids(conn, ids)
    }

    pub fn delete_areas_by_ids(conn: &Connection, ids: &[String]) -> Result<u32, TaskError> {
        batch::delete_areas_by_ids(conn, ids)
    }

    pub fn get_active_task_summary(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<ActiveTaskSummary, TaskError> {
        summary::get_active_task_summary(conn, workspace_id)
    }

    pub fn get_active_project_progress(
        conn: &Connection,
        workspace_id: Option<&str>,
    ) -> Result<Vec<ProjectProgressEntry>, TaskError> {
        summary::get_active_project_progress(conn, workspace_id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

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

    // --- Task CRUD ---

    #[test]
    fn test_create_task_minimal() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Fix bug".to_string(),
            ..Default::default()
        };
        let task = TaskRepository::create_task(&conn, &params).unwrap();
        assert!(task.id.starts_with("task-"));
        assert_eq!(task.title, "Fix bug");
        assert_eq!(task.status, TaskStatus::Pending);
        assert_eq!(task.priority, TaskPriority::Medium);
        assert_eq!(task.source, TaskSource::Agent);
        assert_eq!(task.actual_minutes, 0);
    }

    #[test]
    fn test_create_task_all_fields() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Full task".to_string(),
            description: Some("Description".to_string()),
            active_form: Some("Working".to_string()),
            status: Some(TaskStatus::InProgress),
            priority: Some(TaskPriority::High),
            source: Some(TaskSource::User),
            tags: Some(vec!["tag1".to_string(), "tag2".to_string()]),
            due_date: Some("2026-03-01".to_string()),
            estimated_minutes: Some(120),
            workspace_id: Some("ws-1".to_string()),
            ..Default::default()
        };
        let task = TaskRepository::create_task(&conn, &params).unwrap();
        assert_eq!(task.status, TaskStatus::InProgress);
        assert_eq!(task.priority, TaskPriority::High);
        assert_eq!(task.source, TaskSource::User);
        assert_eq!(task.tags, vec!["tag1", "tag2"]);
        assert!(task.started_at.is_some()); // Auto-set for InProgress
        assert_eq!(task.estimated_minutes, Some(120));
    }

    #[test]
    fn test_get_task_exists() {
        let conn = setup_db();
        let params = TaskCreateParams {
            title: "Test".to_string(),
            ..Default::default()
        };
        let created = TaskRepository::create_task(&conn, &params).unwrap();
        let fetched = TaskRepository::get_task(&conn, &created.id).unwrap();
        assert!(fetched.is_some());
        assert_eq!(fetched.unwrap().id, created.id);
    }

    #[test]
    fn test_get_task_not_found() {
        let conn = setup_db();
        let result = TaskRepository::get_task(&conn, "task-nonexistent").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_update_task_title() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Old".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                title: Some("New".to_string()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.title, "New");
    }

    #[test]
    fn test_update_task_status() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.status, TaskStatus::InProgress);
    }

    #[test]
    fn test_update_task_not_found() {
        let conn = setup_db();
        let result = TaskRepository::update_task(
            &conn,
            "task-missing",
            &TaskUpdateParams {
                title: Some("X".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_update_task_add_tags() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_tags: Some(vec!["b".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.tags.contains(&"a".to_string()));
        assert!(updated.tags.contains(&"b".to_string()));
    }

    #[test]
    fn test_update_task_add_tags_dedup() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.tags.len(), 1);
    }

    #[test]
    fn test_update_task_remove_tags() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Tags".to_string(),
                tags: Some(vec!["a".to_string(), "b".to_string()]),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                remove_tags: Some(vec!["a".to_string()]),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated.tags, vec!["b".to_string()]);
    }

    #[test]
    fn test_update_task_add_note() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Notes".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                add_note: Some("First note".to_string()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.notes.as_ref().unwrap().contains("First note"));
        assert!(updated.notes.as_ref().unwrap().starts_with('['));
    }

    #[test]
    fn test_delete_task() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Delete me".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(TaskRepository::delete_task(&conn, &task.id).unwrap());
        assert!(TaskRepository::get_task(&conn, &task.id).unwrap().is_none());
    }

    #[test]
    fn test_delete_task_not_found() {
        let conn = setup_db();
        assert!(!TaskRepository::delete_task(&conn, "task-missing").unwrap());
    }

    #[test]
    fn test_increment_actual_minutes() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Time".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(task.actual_minutes, 0);
        TaskRepository::increment_actual_minutes(&conn, &task.id, 30).unwrap();
        let updated = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert_eq!(updated.actual_minutes, 30);
        TaskRepository::increment_actual_minutes(&conn, &task.id, 15).unwrap();
        let updated = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert_eq!(updated.actual_minutes, 45);
    }

    // --- List and search ---

    #[test]
    fn test_list_tasks_empty() {
        let conn = setup_db();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.total, 0);
        assert!(result.tasks.is_empty());
    }

    #[test]
    fn test_list_tasks_excludes_completed_by_default() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.tasks[0].title, "Active");
    }

    #[test]
    fn test_list_tasks_include_completed() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(
            &conn,
            &TaskFilter {
                include_completed: true,
                include_backlog: true,
                ..Default::default()
            },
            50,
            0,
        )
        .unwrap();
        assert_eq!(result.total, 2);
    }

    #[test]
    fn test_list_tasks_filter_by_status() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "IP".to_string(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Pending".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(
            &conn,
            &TaskFilter {
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
            50,
            0,
        )
        .unwrap();
        assert_eq!(result.total, 1);
        assert_eq!(result.tasks[0].title, "IP");
    }

    #[test]
    fn test_list_tasks_priority_ordering() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Low".to_string(),
                priority: Some(TaskPriority::Low),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Critical".to_string(),
                priority: Some(TaskPriority::Critical),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 50, 0).unwrap();
        assert_eq!(result.tasks[0].title, "Critical");
        assert_eq!(result.tasks[1].title, "Low");
    }

    #[test]
    fn test_list_tasks_pagination() {
        let conn = setup_db();
        for i in 0..5 {
            TaskRepository::create_task(
                &conn,
                &TaskCreateParams {
                    title: format!("Task {i}"),
                    ..Default::default()
                },
            )
            .unwrap();
        }
        let result = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 2, 0).unwrap();
        assert_eq!(result.total, 5);
        assert_eq!(result.tasks.len(), 2);

        let result2 = TaskRepository::list_tasks(&conn, &TaskFilter::default(), 2, 2).unwrap();
        assert_eq!(result2.tasks.len(), 2);
    }

    #[test]
    fn test_get_subtasks() {
        let conn = setup_db();
        let parent = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Parent".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child 1".to_string(),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Child 2".to_string(),
                parent_task_id: Some(parent.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let subtasks = TaskRepository::get_subtasks(&conn, &parent.id).unwrap();
        assert_eq!(subtasks.len(), 2);
    }

    #[test]
    fn test_search_tasks() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Fix authentication bug".to_string(),
                description: Some("Login fails with OAuth".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Add dark mode".to_string(),
                ..Default::default()
            },
        )
        .unwrap();

        let results = TaskRepository::search_tasks(&conn, "authentication", 10).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].title.contains("authentication"));
    }

    // --- Project CRUD ---

    #[test]
    fn test_create_project() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Dashboard v2".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(project.id.starts_with("proj-"));
        assert_eq!(project.title, "Dashboard v2");
        assert_eq!(project.status, ProjectStatus::Active);
    }

    #[test]
    fn test_delete_project_orphans_tasks() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::delete_project(&conn, &project.id).unwrap();
        let updated_task = TaskRepository::get_task(&conn, &task.id).unwrap().unwrap();
        assert!(updated_task.project_id.is_none());
    }

    #[test]
    fn test_list_projects_with_progress() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                project_id: Some(project.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let result =
            TaskRepository::list_projects(&conn, &ProjectFilter::default(), 50, 0).unwrap();
        assert_eq!(result.projects[0].task_count, 2);
        assert_eq!(result.projects[0].completed_task_count, 1);
    }

    // --- Area CRUD ---

    #[test]
    fn test_create_area() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                description: Some("Core development".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(area.id.starts_with("area-"));
        assert_eq!(area.title, "Engineering");
        assert_eq!(area.workspace_id, "default");
        assert_eq!(area.status, AreaStatus::Active);
    }

    #[test]
    fn test_delete_area_cascades() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Area".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::delete_area(&conn, &area.id).unwrap();
        let updated = TaskRepository::get_project(&conn, &project.id)
            .unwrap()
            .unwrap();
        assert!(updated.area_id.is_none());
    }

    #[test]
    fn test_list_areas_with_counts() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Engineering".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active task".to_string(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done task".to_string(),
                area_id: Some(area.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        let result = TaskRepository::list_areas(&conn, &AreaFilter::default(), 50, 0).unwrap();
        assert_eq!(result.areas[0].project_count, 1);
        assert_eq!(result.areas[0].task_count, 2);
        assert_eq!(result.areas[0].active_task_count, 1);
    }

    // --- Dependencies ---

    #[test]
    fn test_add_dependency() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocker".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocked".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();

        let blocked_by = TaskRepository::get_blocked_by(&conn, &t2.id).unwrap();
        assert_eq!(blocked_by.len(), 1);
        assert_eq!(blocked_by[0].blocker_task_id, t1.id);

        let blocks = TaskRepository::get_blocks(&conn, &t1.id).unwrap();
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].blocked_task_id, t2.id);
    }

    #[test]
    fn test_add_dependency_duplicate_ignored() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Duplicate — should not error
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();

        let deps = TaskRepository::get_blocked_by(&conn, &t2.id).unwrap();
        assert_eq!(deps.len(), 1);
    }

    #[test]
    fn test_remove_dependency() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        assert!(TaskRepository::remove_dependency(&conn, &t1.id, &t2.id).unwrap());
        assert!(!TaskRepository::remove_dependency(&conn, &t1.id, &t2.id).unwrap());
    }

    #[test]
    fn test_circular_dependency_simple() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t2 → t1 create cycle? Yes: t1 → t2 → t1
        assert!(TaskRepository::has_circular_dependency(&conn, &t2.id, &t1.id).unwrap());
    }

    #[test]
    fn test_circular_dependency_transitive() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        TaskRepository::add_dependency(&conn, &t2.id, &t3.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t3 → t1 create cycle? Yes: t1 → t2 → t3 → t1
        assert!(TaskRepository::has_circular_dependency(&conn, &t3.id, &t1.id).unwrap());
    }

    #[test]
    fn test_no_circular_dependency() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        // Would t1 → t3 create cycle? No.
        assert!(!TaskRepository::has_circular_dependency(&conn, &t1.id, &t3.id).unwrap());
    }

    #[test]
    fn test_blocked_task_count() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocker".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Blocked".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::add_dependency(&conn, &t1.id, &t2.id, DependencyRelationship::Blocks)
            .unwrap();
        let count = TaskRepository::get_blocked_task_count(&conn, None).unwrap();
        assert_eq!(count, 1);
    }

    // --- Activity ---

    #[test]
    fn test_log_and_get_activity() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::log_activity(
            &conn,
            &LogActivityParams {
                task_id: task.id.clone(),
                session_id: None,
                event_id: None,
                action: ActivityAction::Created,
                old_value: None,
                new_value: None,
                detail: Some("Task created".to_string()),
                minutes_logged: None,
            },
        )
        .unwrap();
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert_eq!(activity.len(), 1);
        assert_eq!(activity[0].action, ActivityAction::Created);
        assert_eq!(activity[0].detail.as_deref(), Some("Task created"));
    }

    #[test]
    fn test_activity_ordered_desc() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Test".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        for action in [ActivityAction::Created, ActivityAction::Updated] {
            TaskRepository::log_activity(
                &conn,
                &LogActivityParams {
                    task_id: task.id.clone(),
                    session_id: None,
                    event_id: None,
                    action,
                    old_value: None,
                    new_value: None,
                    detail: None,
                    minutes_logged: None,
                },
            )
            .unwrap();
        }
        let activity = TaskRepository::get_activity(&conn, &task.id, 10).unwrap();
        assert!(activity[0].id > activity[1].id); // Most recent first
    }

    // --- Context summaries ---

    #[test]
    fn test_active_task_summary() {
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
                title: "Pending".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let summary = TaskRepository::get_active_task_summary(&conn, None).unwrap();
        assert_eq!(summary.in_progress.len(), 1);
        assert_eq!(summary.pending_count, 1);
    }

    #[test]
    fn test_active_project_progress() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "My Project".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".to_string(),
                project_id: Some(project.id.clone()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".to_string(),
                project_id: Some(project.id),
                ..Default::default()
            },
        )
        .unwrap();
        let progress = TaskRepository::get_active_project_progress(&conn, None).unwrap();
        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].title, "My Project");
        assert_eq!(progress[0].completed, 1);
        assert_eq!(progress[0].total, 2);
    }

    #[test]
    fn test_active_project_progress_filters_workspace() {
        let conn = setup_db();
        let ws_one_project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Workspace One".to_string(),
                workspace_id: Some("ws-1".to_string()),
                ..Default::default()
            },
        )
        .unwrap();
        let ws_two_project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Workspace Two".to_string(),
                workspace_id: Some("ws-2".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "WS1 Done".to_string(),
                project_id: Some(ws_one_project.id),
                workspace_id: Some("ws-1".to_string()),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "WS2 Pending".to_string(),
                project_id: Some(ws_two_project.id),
                workspace_id: Some("ws-2".to_string()),
                ..Default::default()
            },
        )
        .unwrap();

        let progress = TaskRepository::get_active_project_progress(&conn, Some("ws-1")).unwrap();
        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].title, "Workspace One");
        assert_eq!(progress[0].completed, 1);
        assert_eq!(progress[0].total, 1);
    }

    // --- FK empty string normalization ---

    #[test]
    fn create_task_normalizes_empty_project_id() {
        let conn = setup_db();
        // Empty string project_id should be normalized to NULL, not trigger FK failure
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task with empty project".to_string(),
                project_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(task.project_id.is_none());
    }

    #[test]
    fn create_task_normalizes_empty_area_id() {
        let conn = setup_db();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task with empty area".to_string(),
                area_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(task.area_id.is_none());
    }

    #[test]
    fn update_task_normalizes_empty_project_id() {
        let conn = setup_db();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Proj".to_string(),
                ..Default::default()
            },
        )
        .unwrap();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task".to_string(),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(task.project_id.as_deref(), Some(project.id.as_str()));

        // Update with empty string should set to NULL
        let updated = TaskRepository::update_task(
            &conn,
            &task.id,
            &TaskUpdateParams {
                project_id: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap()
        .unwrap();
        assert!(updated.project_id.is_none());
    }

    // --- Batch operations ---

    #[test]
    fn test_delete_tasks_by_ids() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let deleted =
            TaskRepository::delete_tasks_by_ids(&conn, &[t1.id.clone(), t2.id.clone()]).unwrap();
        assert_eq!(deleted, 2);
        assert!(TaskRepository::get_task(&conn, &t1.id).unwrap().is_none());
        assert!(TaskRepository::get_task(&conn, &t3.id).unwrap().is_some());
    }

    #[test]
    fn test_delete_tasks_by_ids_empty() {
        let conn = setup_db();
        let deleted = TaskRepository::delete_tasks_by_ids(&conn, &[]).unwrap();
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_delete_tasks_by_ids_nonexistent() {
        let conn = setup_db();
        let deleted =
            TaskRepository::delete_tasks_by_ids(&conn, &["task-fake".to_string()]).unwrap();
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_delete_tasks_by_ids_mixed_existing() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let deleted = TaskRepository::delete_tasks_by_ids(
            &conn,
            &[t1.id.clone(), "task-fake".to_string(), t2.id.clone()],
        )
        .unwrap();
        assert_eq!(deleted, 2);
    }

    #[test]
    fn test_delete_tasks_by_filter_status() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Active".into(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Done2".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            status: Some(TaskStatus::Completed),
            include_completed: true,
            ..Default::default()
        };
        let deleted = TaskRepository::delete_tasks_by_filter(&conn, &filter).unwrap();
        assert_eq!(deleted, 2);
        // Active task remains
        let remaining = TaskRepository::list_tasks(
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
        assert_eq!(remaining.total, 1);
        assert_eq!(remaining.tasks[0].title, "Active");
    }

    #[test]
    fn test_delete_tasks_by_filter_project() {
        let conn = setup_db();
        let proj = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "In project".into(),
                project_id: Some(proj.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "No project".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            project_id: Some(proj.id),
            include_completed: true,
            include_backlog: true,
            include_deferred: true,
            ..Default::default()
        };
        let deleted = TaskRepository::delete_tasks_by_filter(&conn, &filter).unwrap();
        assert_eq!(deleted, 1);
    }

    #[test]
    fn test_delete_tasks_by_filter_empty_match() {
        let conn = setup_db();
        let filter = TaskFilter {
            status: Some(TaskStatus::Completed),
            include_completed: true,
            ..Default::default()
        };
        let deleted = TaskRepository::delete_tasks_by_filter(&conn, &filter).unwrap();
        assert_eq!(deleted, 0);
    }

    #[test]
    fn test_count_tasks_by_ids() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let count = TaskRepository::count_tasks_by_ids(&conn, &[t1.id, t2.id]).unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn test_count_tasks_by_filter() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            status: Some(TaskStatus::Completed),
            include_completed: true,
            ..Default::default()
        };
        let count = TaskRepository::count_tasks_by_filter(&conn, &filter).unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn test_update_tasks_by_ids_changes_status() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t3 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let updated = TaskRepository::update_tasks_by_ids(
            &conn,
            &[t1.id.clone(), t2.id.clone()],
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(updated, 2);

        let a = TaskRepository::get_task(&conn, &t1.id).unwrap().unwrap();
        assert_eq!(a.status, TaskStatus::Completed);
        assert!(a.completed_at.is_some());
        let c = TaskRepository::get_task(&conn, &t3.id).unwrap().unwrap();
        assert_eq!(c.status, TaskStatus::Pending);
    }

    #[test]
    fn test_update_tasks_by_ids_empty() {
        let conn = setup_db();
        let updated = TaskRepository::update_tasks_by_ids(
            &conn,
            &[],
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(updated, 0);
    }

    #[test]
    fn test_update_tasks_by_filter_status() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".into(),
                status: Some(TaskStatus::InProgress),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            status: Some(TaskStatus::Pending),
            include_completed: true,
            include_backlog: true,
            include_deferred: true,
            ..Default::default()
        };
        let updated = TaskRepository::update_tasks_by_filter(
            &conn,
            &filter,
            &TaskUpdateParams {
                status: Some(TaskStatus::Cancelled),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(updated, 2);
    }

    #[test]
    fn test_update_tasks_by_filter_project() {
        let conn = setup_db();
        let proj = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "In project".into(),
                project_id: Some(proj.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "No project".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            project_id: Some(proj.id),
            include_completed: true,
            include_backlog: true,
            include_deferred: true,
            ..Default::default()
        };
        let updated = TaskRepository::update_tasks_by_filter(
            &conn,
            &filter,
            &TaskUpdateParams {
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(updated, 1);
    }

    #[test]
    fn test_delete_projects_by_ids() {
        let conn = setup_db();
        let p1 = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let p2 = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "P2".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let deleted =
            TaskRepository::delete_projects_by_ids(&conn, &[p1.id.clone(), p2.id.clone()]).unwrap();
        assert_eq!(deleted, 2);
        assert!(
            TaskRepository::get_project(&conn, &p1.id)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn test_delete_areas_by_ids() {
        let conn = setup_db();
        let a1 = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "A1".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let a2 = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "A2".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let deleted =
            TaskRepository::delete_areas_by_ids(&conn, &[a1.id.clone(), a2.id.clone()]).unwrap();
        assert_eq!(deleted, 2);
        assert!(TaskRepository::get_area(&conn, &a1.id).unwrap().is_none());
    }

    #[test]
    fn test_delete_areas_by_ids_orphans_related_records() {
        let conn = setup_db();
        let area = TaskRepository::create_area(
            &conn,
            &AreaCreateParams {
                title: "Area".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let project = TaskRepository::create_project(
            &conn,
            &ProjectCreateParams {
                title: "Project".into(),
                area_id: Some(area.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();
        let task = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "Task".into(),
                area_id: Some(area.id.clone()),
                project_id: Some(project.id.clone()),
                ..Default::default()
            },
        )
        .unwrap();

        let deleted =
            TaskRepository::delete_areas_by_ids(&conn, std::slice::from_ref(&area.id)).unwrap();
        assert_eq!(deleted, 1);
        assert!(TaskRepository::get_area(&conn, &area.id).unwrap().is_none());
        assert!(
            TaskRepository::get_project(&conn, &project.id)
                .unwrap()
                .unwrap()
                .area_id
                .is_none()
        );
        assert!(
            TaskRepository::get_task(&conn, &task.id)
                .unwrap()
                .unwrap()
                .area_id
                .is_none()
        );
    }

    #[test]
    fn test_get_tasks_by_ids() {
        let conn = setup_db();
        let t1 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let t2 = TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "C".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let tasks =
            TaskRepository::get_tasks_by_ids(&conn, &[t1.id.clone(), t2.id.clone()]).unwrap();
        assert_eq!(tasks.len(), 2);
    }

    #[test]
    fn test_get_tasks_by_filter() {
        let conn = setup_db();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "A".into(),
                status: Some(TaskStatus::Completed),
                ..Default::default()
            },
        )
        .unwrap();
        TaskRepository::create_task(
            &conn,
            &TaskCreateParams {
                title: "B".into(),
                ..Default::default()
            },
        )
        .unwrap();

        let filter = TaskFilter {
            status: Some(TaskStatus::Completed),
            include_completed: true,
            ..Default::default()
        };
        let tasks = TaskRepository::get_tasks_by_filter(&conn, &filter).unwrap();
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].title, "A");
    }
}
