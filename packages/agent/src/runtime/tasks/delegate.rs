//! Real `TaskManagerDelegate` backed by `crate::runtime::tasks::TaskService`.

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::events::ConnectionPool;
use crate::runtime::tasks::service::TaskService;
use crate::runtime::tasks::types::{TaskCreateParams, TaskFilter, TaskUpdateParams, TaskStatus};
use crate::tools::errors::ToolError;
use crate::tools::traits::TaskManagerDelegate;

/// Real task manager backed by `SQLite` via `TaskService`.
pub struct SqliteTaskManagerDelegate {
    pool: ConnectionPool,
}

impl SqliteTaskManagerDelegate {
    /// Create a new task manager.
    pub fn new(pool: ConnectionPool) -> Self {
        Self { pool }
    }

    #[allow(clippy::cast_possible_truncation)]
    fn handle_action(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        let conn = self.pool.get().map_err(ToolError::internal)?;

        match action {
            "create" => {
                let cp: TaskCreateParams =
                    serde_json::from_value(params).map_err(ToolError::internal)?;
                if cp.title.is_empty() {
                    return Err(ToolError::internal("title is required for create"));
                }
                let task = TaskService::create_task(&conn, &cp).map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "update" => {
                let task_id = params
                    .get("taskId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for update"))?
                    .to_string();
                let get_str =
                    |key: &str| params.get(key).and_then(Value::as_str).map(String::from);
                let up = TaskUpdateParams {
                    title: get_str("title"),
                    description: get_str("description"),
                    status: get_str("status")
                        .and_then(|s| serde_json::from_value(Value::String(s)).ok()),
                    add_note: get_str("note"),
                    ..Default::default()
                };
                let task = TaskService::update_task(&conn, &task_id, &up, None)
                    .map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "get" => {
                let task_id = params
                    .get("taskId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for get"))?;
                let details =
                    TaskService::get_task(&conn, task_id).map_err(ToolError::internal)?;
                serde_json::to_value(&details).map_err(ToolError::internal)
            }
            "list" => {
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0) as u32;
                let filter = TaskFilter {
                    status: params
                        .get("status")
                        .and_then(Value::as_str)
                        .and_then(|s| serde_json::from_value(Value::String(s.to_string())).ok()),
                    include_completed: params
                        .get("includeCompleted")
                        .and_then(Value::as_bool)
                        .unwrap_or(true),
                    ..Default::default()
                };
                let result = TaskService::list_tasks(&conn, &filter, limit, offset)
                    .map_err(ToolError::internal)?;
                Ok(
                    json!({ "tasks": serde_json::to_value(&result.tasks).map_err(ToolError::internal)?, "count": result.total }),
                )
            }
            "search" => {
                let query = params
                    .get("query")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as u32;
                let tasks =
                    TaskService::search_tasks(&conn, query, limit).map_err(ToolError::internal)?;
                Ok(
                    json!({ "tasks": serde_json::to_value(&tasks).map_err(ToolError::internal)?, "count": tasks.len() }),
                )
            }
            "done" => {
                let task_id = params
                    .get("taskId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for done"))?
                    .to_string();
                let up = TaskUpdateParams {
                    status: Some(TaskStatus::Completed),
                    ..Default::default()
                };
                let task = TaskService::update_task(&conn, &task_id, &up, None)
                    .map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "delete" => {
                let task_id = params
                    .get("taskId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for delete"))?;
                let deleted =
                    TaskService::delete_task(&conn, task_id, None).map_err(ToolError::internal)?;
                Ok(json!({ "success": deleted, "taskId": task_id }))
            }
            "add_note" => {
                let task_id = params
                    .get("taskId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("taskId is required for add_note"))?
                    .to_string();
                let note = params
                    .get("note")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ToolError::internal("note is required for add_note"))?;
                if note.is_empty() {
                    return Err(ToolError::internal("note cannot be empty"));
                }
                let up = TaskUpdateParams {
                    add_note: Some(note.to_string()),
                    ..Default::default()
                };
                let task = TaskService::update_task(&conn, &task_id, &up, None)
                    .map_err(ToolError::internal)?;
                serde_json::to_value(&task).map_err(ToolError::internal)
            }
            "batch_create" => {
                let items: Vec<TaskCreateParams> = params
                    .get("items")
                    .and_then(|v| serde_json::from_value(v.clone()).ok())
                    .unwrap_or_default();
                TaskService::batch_create_tasks(&conn, &items, None).map_err(ToolError::internal)
            }
            _ => Err(ToolError::internal(format!("Unknown action: {action}"))),
        }
    }
}

#[async_trait]
impl TaskManagerDelegate for SqliteTaskManagerDelegate {
    async fn execute_action(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        self.handle_action(action, params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::ConnectionConfig;

    fn setup_pool() -> ConnectionPool {
        let pool = crate::events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
            crate::runtime::tasks::migrations::run_migrations(&conn).unwrap();
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
        let _ = delegate
            .execute_action(
                "create",
                json!({"title": "Task A", "status": "in_progress"}),
            )
            .await
            .unwrap();
        let _ = delegate
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
    async fn search_tasks() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let _ = delegate
            .execute_action("create", json!({"title": "Fix authentication"}))
            .await
            .unwrap();
        let _ = delegate
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
    async fn done_action() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let task = delegate
            .execute_action("create", json!({"title": "To Complete"}))
            .await
            .unwrap();
        let tid = task["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("done", json!({"taskId": tid}))
            .await
            .unwrap();
        assert_eq!(result["status"], "completed");
        assert!(result.get("completedAt").is_some());
    }

    #[tokio::test]
    async fn done_stale_task() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let task = delegate
            .execute_action(
                "create",
                json!({"title": "Stale", "status": "in_progress"}),
            )
            .await
            .unwrap();
        let tid = task["id"].as_str().unwrap().to_string();
        // Mark stale
        let _ = delegate
            .execute_action("update", json!({"taskId": tid, "status": "stale"}))
            .await
            .unwrap();
        // Complete it
        let result = delegate
            .execute_action("done", json!({"taskId": tid}))
            .await
            .unwrap();
        assert_eq!(result["status"], "completed");
    }

    #[tokio::test]
    async fn add_note() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let task = delegate
            .execute_action("create", json!({"title": "Note Test"}))
            .await
            .unwrap();
        let tid = task["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("add_note", json!({"taskId": tid, "note": "First note"}))
            .await
            .unwrap();
        assert!(result["notes"].as_str().unwrap().contains("First note"));

        // Add second note
        let result = delegate
            .execute_action("add_note", json!({"taskId": tid, "note": "Second note"}))
            .await
            .unwrap();
        let notes = result["notes"].as_str().unwrap();
        assert!(notes.contains("First note"));
        assert!(notes.contains("Second note"));
    }

    #[tokio::test]
    async fn add_note_empty_rejected() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let task = delegate
            .execute_action("create", json!({"title": "Note Test"}))
            .await
            .unwrap();
        let tid = task["id"].as_str().unwrap().to_string();
        let result = delegate
            .execute_action("add_note", json!({"taskId": tid, "note": ""}))
            .await;
        assert!(result.is_err());
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

    // --- Batch operations ---

    #[tokio::test]
    async fn batch_create_multiple() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action(
                "batch_create",
                json!({"items": [{"title": "A"}, {"title": "B"}, {"title": "C"}]}),
            )
            .await
            .unwrap();
        assert_eq!(result["affected"], 3);
        assert_eq!(result["ids"].as_array().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn batch_create_empty() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action("batch_create", json!({"items": []}))
            .await
            .unwrap();
        assert_eq!(result["affected"], 0);
    }

    #[tokio::test]
    async fn batch_create_invalid_item() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate
            .execute_action(
                "batch_create",
                json!({"items": [{"title": "Good"}, {"title": ""}, {"title": "Also Good"}]}),
            )
            .await;
        assert!(result.is_err());
    }

    // --- Error handling ---

    #[tokio::test]
    async fn unknown_action_returns_error() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        let result = delegate.execute_action("unknown", json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn removed_actions_return_error() {
        let delegate = SqliteTaskManagerDelegate::new(setup_pool());
        for action in [
            "create_project",
            "log_time",
            "add_dependency",
            "batch_delete",
            "batch_update",
            "create_area",
            "list_projects",
            "list_areas",
        ] {
            let result = delegate.execute_action(action, json!({})).await;
            assert!(result.is_err(), "Action {action} should be unknown");
        }
    }
}
