//! Real `TaskManagerDelegate` backed by `tron_runtime::tasks::TaskService`.
//!
//! Provides the `TaskManager` tool with actual database access for CRUD
//! operations on tasks, projects, and areas. Each entity type has its own
//! handler method; the outer dispatcher routes by action name.

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_events::ConnectionPool;
use tron_runtime::tasks::service::TaskService;
use tron_runtime::tasks::types::{
    AreaCreateParams, AreaFilter, AreaUpdateParams, ProjectCreateParams, ProjectFilter,
    ProjectUpdateParams, TaskCreateParams, TaskFilter, TaskUpdateParams,
};
use tron_tools::errors::ToolError;
use tron_tools::traits::TaskManagerDelegate;

/// Real task manager backed by `SQLite` via `TaskService`.
pub struct SqliteTaskManagerDelegate {
    pool: ConnectionPool,
}

impl SqliteTaskManagerDelegate {
    pub fn new(pool: ConnectionPool) -> Self {
        Self { pool }
    }

    #[allow(clippy::cast_possible_truncation)]
    fn handle_task(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        let conn = self.pool.get().map_err(ToolError::internal)?;

        match action {
            "create" => {
                let cp: TaskCreateParams = serde_json::from_value(params).map_err(ToolError::internal)?;
                if cp.title.is_empty() {
                    return Err(ToolError::internal("title is required for create"));
                }
                let task = TaskService::create_task(&conn, &cp).map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "update" => {
                let task_id = params.get("taskId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for update"))?
                    .to_string();
                let get_str = |key: &str| params.get(key).and_then(Value::as_str).map(String::from);
                let up = TaskUpdateParams {
                    title: get_str("title"),
                    description: get_str("description"),
                    status: get_str("status")
                        .and_then(|s| serde_json::from_value(Value::String(s)).ok()),
                    priority: get_str("priority")
                        .and_then(|s| serde_json::from_value(Value::String(s)).ok()),
                    project_id: get_str("projectId"),
                    area_id: get_str("areaId"),
                    add_note: get_str("note"),
                    ..Default::default()
                };
                let task = TaskService::update_task(&conn, &task_id, &up, None).map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "get" => {
                let task_id = params.get("taskId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for get"))?;
                let details = TaskService::get_task(&conn, task_id).map_err(ToolError::internal)?;
                serde_json::to_value(&details).map_err(ToolError::internal)
            }
            "list" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0) as u32;
                let filter = TaskFilter {
                    status: params.get("status").and_then(Value::as_str)
                        .and_then(|s| serde_json::from_value(Value::String(s.to_string())).ok()),
                    project_id: params.get("projectId").and_then(Value::as_str).map(String::from),
                    area_id: params.get("areaId").and_then(Value::as_str).map(String::from),
                    include_completed: params.get("includeCompleted").and_then(Value::as_bool).unwrap_or(true),
                    include_deferred: params.get("includeDeferred").and_then(Value::as_bool).unwrap_or(true),
                    include_backlog: params.get("includeBacklog").and_then(Value::as_bool).unwrap_or(true),
                    ..Default::default()
                };
                let result = TaskService::list_tasks(&conn, &filter, limit, offset).map_err(ToolError::internal)?;
                // Use "count" for backwards compatibility with existing consumers
                Ok(json!({ "tasks": serde_json::to_value(&result.tasks).map_err(ToolError::internal)?, "count": result.total }))
            }
            "search" => {
                let query = params.get("query").and_then(Value::as_str).unwrap_or_default();
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let tasks = TaskService::search_tasks(&conn, query, limit).map_err(ToolError::internal)?;
                Ok(json!({ "tasks": serde_json::to_value(&tasks).map_err(ToolError::internal)?, "count": tasks.len() }))
            }
            "log_time" => {
                let task_id = params.get("taskId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for log_time"))?;
                #[allow(clippy::cast_possible_truncation)]
                let minutes = params.get("minutes").and_then(Value::as_i64)
                    .ok_or_else(|| ToolError::internal("minutes is required for log_time"))? as i32;
                TaskService::log_time(&conn, task_id, minutes, None).map_err(ToolError::internal)?;
                Ok(json!({ "success": true, "taskId": task_id, "minutesLogged": minutes }))
            }
            "delete" => {
                let task_id = params.get("taskId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for delete"))?;
                let deleted = TaskService::delete_task(&conn, task_id, None).map_err(ToolError::internal)?;
                Ok(json!({ "success": deleted, "taskId": task_id }))
            }
            _ => unreachable!(),
        }
    }

    #[allow(clippy::needless_pass_by_value, clippy::cast_possible_truncation)]
    fn handle_project(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        let conn = self.pool.get().map_err(ToolError::internal)?;

        match action {
            "create_project" => {
                let title = params.get("projectTitle").or_else(|| params.get("title"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("projectTitle is required"))?;
                let cp = ProjectCreateParams {
                    title: title.to_string(),
                    description: params.get("description").and_then(Value::as_str).map(String::from),
                    ..Default::default()
                };
                let project = TaskService::create_project(&conn, &cp).map_err(ToolError::internal)?;
                serde_json::to_value(&project).map_err(ToolError::internal)
            }
            "update_project" => {
                let id = params.get("projectId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("projectId is required"))?;
                let up = ProjectUpdateParams {
                    title: params.get("title").or_else(|| params.get("projectTitle"))
                        .and_then(Value::as_str).map(String::from),
                    description: params.get("description").and_then(Value::as_str).map(String::from),
                    status: params.get("status").and_then(Value::as_str)
                        .and_then(|s| serde_json::from_value(Value::String(s.to_string())).ok()),
                    ..Default::default()
                };
                let project = TaskService::update_project(&conn, id, &up).map_err(ToolError::internal)?;
                serde_json::to_value(&project).map_err(ToolError::internal)
            }
            "get_project" => {
                let id = params.get("projectId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("projectId is required"))?;
                let project = TaskService::get_project(&conn, id).map_err(ToolError::internal)?;
                serde_json::to_value(&project).map_err(ToolError::internal)
            }
            "delete_project" => {
                let id = params.get("projectId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("projectId is required"))?;
                let deleted = TaskService::delete_project(&conn, id).map_err(ToolError::internal)?;
                Ok(json!({ "success": deleted, "projectId": id }))
            }
            "list_projects" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0) as u32;
                let filter = ProjectFilter::default();
                let result = TaskService::list_projects(&conn, &filter, limit, offset).map_err(ToolError::internal)?;
                Ok(json!({ "projects": serde_json::to_value(&result.projects).map_err(ToolError::internal)?, "count": result.total }))
            }
            _ => unreachable!(),
        }
    }

    #[allow(clippy::needless_pass_by_value, clippy::cast_possible_truncation)]
    fn handle_area(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        let conn = self.pool.get().map_err(ToolError::internal)?;

        match action {
            "create_area" => {
                let title = params.get("areaTitle").or_else(|| params.get("title"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("areaTitle is required"))?;
                let cp = AreaCreateParams {
                    title: title.to_string(),
                    description: params.get("description").and_then(Value::as_str).map(String::from),
                    ..Default::default()
                };
                let area = TaskService::create_area(&conn, &cp).map_err(ToolError::internal)?;
                serde_json::to_value(&area).map_err(ToolError::internal)
            }
            "update_area" => {
                let id = params.get("areaId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("areaId is required"))?;
                let up = AreaUpdateParams {
                    title: params.get("title").or_else(|| params.get("areaTitle"))
                        .and_then(Value::as_str).map(String::from),
                    description: params.get("description").and_then(Value::as_str).map(String::from),
                    ..Default::default()
                };
                let area = TaskService::update_area(&conn, id, &up).map_err(ToolError::internal)?;
                Ok(json!({ "success": true, "areaId": id, "area": serde_json::to_value(&area).map_err(ToolError::internal)? }))
            }
            "get_area" => {
                let id = params.get("areaId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("areaId is required"))?;
                let area = TaskService::get_area(&conn, id).map_err(ToolError::internal)?;
                serde_json::to_value(&area).map_err(ToolError::internal)
            }
            "delete_area" => {
                let id = params.get("areaId").and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("areaId is required"))?;
                let deleted = TaskService::delete_area(&conn, id).map_err(ToolError::internal)?;
                Ok(json!({ "success": deleted, "areaId": id }))
            }
            "list_areas" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0) as u32;
                let filter = AreaFilter::default();
                let result = TaskService::list_areas(&conn, &filter, limit, offset).map_err(ToolError::internal)?;
                Ok(json!({ "areas": serde_json::to_value(&result.areas).map_err(ToolError::internal)?, "count": result.total }))
            }
            _ => unreachable!(),
        }
    }
}

#[async_trait]
impl TaskManagerDelegate for SqliteTaskManagerDelegate {
    async fn execute_action(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        match action {
            "create" | "update" | "get" | "list" | "search" | "log_time" | "delete" => {
                self.handle_task(action, params)
            }
            "create_project" | "update_project" | "get_project" | "delete_project"
            | "list_projects" => self.handle_project(action, params),
            "create_area" | "update_area" | "get_area" | "delete_area" | "list_areas" => {
                self.handle_area(action, params)
            }
            other => Err(ToolError::internal(format!("Unknown action: {other}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_events::ConnectionConfig;

    fn setup_pool() -> ConnectionPool {
        let pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
            let _ = tron_runtime::tasks::migrations::run_migrations(&conn).unwrap();
        }
        pool
    }

    // --- Task CRUD ---

    #[tokio::test]
    async fn create_and_get_task() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create", json!({"title": "Test Task"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());
        assert_eq!(result["title"], "Test Task");

        let id = result["id"].as_str().unwrap();
        let detail = delegate
            .execute_action("get", json!({"taskId": id}))
            .await
            .unwrap();
        // TaskWithDetails uses #[serde(flatten)] — task fields are at top level
        assert_eq!(detail["id"].as_str(), Some(id));
        assert_eq!(detail["title"], "Test Task");
    }

    #[tokio::test]
    async fn list_tasks_empty() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate.execute_action("list", json!({})).await.unwrap();
        assert_eq!(result["count"], 0);
    }

    #[tokio::test]
    async fn list_tasks_with_status_filter() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        delegate
            .execute_action("create", json!({"title": "Task A", "status": "in_progress"}))
            .await
            .unwrap();
        delegate
            .execute_action("create", json!({"title": "Task B"}))
            .await
            .unwrap();
        let result = delegate
            .execute_action("list", json!({"status": "in_progress"}))
            .await
            .unwrap();
        assert_eq!(result["count"], 1);
    }

    #[tokio::test]
    async fn list_tasks_with_project_filter() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let proj = delegate
            .execute_action("create_project", json!({"projectTitle": "P1"}))
            .await
            .unwrap();
        let pid = proj["id"].as_str().unwrap().to_string();
        delegate
            .execute_action("create", json!({"title": "In Project", "projectId": pid}))
            .await
            .unwrap();
        delegate
            .execute_action("create", json!({"title": "No Project"}))
            .await
            .unwrap();
        let result = delegate
            .execute_action("list", json!({"projectId": pid}))
            .await
            .unwrap();
        assert_eq!(result["count"], 1);
    }

    #[tokio::test]
    async fn search_tasks() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        delegate
            .execute_action("create", json!({"title": "Fix authentication"}))
            .await
            .unwrap();
        delegate
            .execute_action("create", json!({"title": "Add logging"}))
            .await
            .unwrap();
        let result = delegate
            .execute_action("search", json!({"query": "authentication"}))
            .await
            .unwrap();
        assert!(result["count"].as_u64().unwrap() >= 1);
    }

    #[tokio::test]
    async fn log_time() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let task = delegate
            .execute_action("create", json!({"title": "Time Track"}))
            .await
            .unwrap();
        let tid = task["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("log_time", json!({"taskId": tid, "minutes": 30}))
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["minutesLogged"], 30);
    }

    #[tokio::test]
    async fn delete_task() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create", json!({"title": "To Delete"}))
            .await
            .unwrap();
        let id = result["id"].as_str().unwrap().to_string();

        let deleted = delegate
            .execute_action("delete", json!({"taskId": id}))
            .await
            .unwrap();
        assert_eq!(deleted["success"], true);
    }

    // --- Project CRUD ---

    #[tokio::test]
    async fn create_and_list_project() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create_project", json!({"projectTitle": "My Project"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());

        let list = delegate
            .execute_action("list_projects", json!({}))
            .await
            .unwrap();
        assert_eq!(list["count"], 1);
    }

    #[tokio::test]
    async fn get_project_returns_details() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let proj = delegate
            .execute_action("create_project", json!({"projectTitle": "My Project"}))
            .await
            .unwrap();
        let pid = proj["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("get_project", json!({"projectId": pid}))
            .await
            .unwrap();
        assert_eq!(result["title"], "My Project");
    }

    #[tokio::test]
    async fn update_project() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let proj = delegate
            .execute_action("create_project", json!({"projectTitle": "Original"}))
            .await
            .unwrap();
        let pid = proj["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("update_project", json!({"projectId": pid, "title": "Updated"}))
            .await
            .unwrap();
        assert_eq!(result["title"], "Updated");
    }

    #[tokio::test]
    async fn delete_project() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let proj = delegate
            .execute_action("create_project", json!({"projectTitle": "To Delete"}))
            .await
            .unwrap();
        let pid = proj["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("delete_project", json!({"projectId": pid}))
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    // --- Area CRUD ---

    #[tokio::test]
    async fn create_and_list_area() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("create_area", json!({"areaTitle": "My Area"}))
            .await
            .unwrap();
        assert!(result.get("id").is_some());

        let list = delegate
            .execute_action("list_areas", json!({}))
            .await
            .unwrap();
        assert_eq!(list["count"], 1);
    }

    #[tokio::test]
    async fn get_area_returns_details() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let area = delegate
            .execute_action("create_area", json!({"areaTitle": "My Area"}))
            .await
            .unwrap();
        let aid = area["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("get_area", json!({"areaId": aid}))
            .await
            .unwrap();
        assert_eq!(result["title"], "My Area");
    }

    #[tokio::test]
    async fn update_area() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let area = delegate
            .execute_action("create_area", json!({"areaTitle": "Old Title"}))
            .await
            .unwrap();
        let aid = area["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("update_area", json!({"areaId": aid, "title": "New Title"}))
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn delete_area() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let area = delegate
            .execute_action("create_area", json!({"areaTitle": "To Delete"}))
            .await
            .unwrap();
        let aid = area["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("delete_area", json!({"areaId": aid}))
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    // --- Error handling ---

    #[tokio::test]
    async fn unknown_action_returns_error() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate.execute_action("unknown", json!({})).await;
        assert!(result.is_err());
    }
}
