//! `TaskManager` tool — persistent task tracker.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use crate::events::ConnectionPool;
use crate::runtime::tasks::service::TaskService;
use crate::runtime::tasks::types::{TaskCreateParams, TaskFilter, TaskUpdateParams, TaskStatus};
use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::validate_required_string;

const VALID_ACTIONS: &[&str] = &[
    "create",
    "update",
    "get",
    "list",
    "done",
    "delete",
    "add_note",
    "search",
    "batch_create",
];

/// The `TaskManager` tool manages persistent tasks.
pub struct TaskManagerTool {
    pool: Arc<ConnectionPool>,
}

impl TaskManagerTool {
    /// Create a new `TaskManager` tool with the given connection pool.
    pub fn new(pool: Arc<ConnectionPool>) -> Self {
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
impl TronTool for TaskManagerTool {
    fn name(&self) -> &str {
        "TaskManager"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "TaskManager",
            "Persistent task tracker. Use for non-trivial, multi-step work.\n\n\
## Actions\n\
- **create**: Create a task. Required: title. Optional: description, status, parentTaskId\n\
- **update**: Update a task. Required: taskId. Optional: status, title, description\n\
- **get**: Get task details with subtasks and activity. Required: taskId\n\
- **list**: List tasks. Optional: status filter, limit, offset\n\
- **done**: Mark task completed. Required: taskId\n\
- **delete**: Delete a task. Required: taskId\n\
- **add_note**: Append a timestamped note. Required: taskId, note\n\
- **search**: Full-text search. Required: query. Optional: limit\n\
- **batch_create**: Create multiple tasks atomically. Required: items (array of {title, ...})\n\n\
## Status Model\n\
pending → in_progress → completed/cancelled/stale\n\n\
Stale tasks are from previous sessions — resume (set in_progress) or close them (done/cancelled).",
        )
        .required_property("action", json!({
            "type": "string",
            "enum": VALID_ACTIONS,
            "description": "The management action to perform"
        }))
        .property("taskId", json!({"type": "string"}))
        .property("title", json!({"type": "string"}))
        .property("description", json!({"type": "string"}))
        .property("status", json!({"type": "string"}))
        .property("parentTaskId", json!({"type": "string"}))
        .property("note", json!({"type": "string"}))
        .property("query", json!({"type": "string"}))
        .property("limit", json!({"type": "number"}))
        .property("offset", json!({"type": "number"}))
        .property("items", json!({
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "description": {"type": "string"},
                    "status": {"type": "string"},
                    "parentTaskId": {"type": "string"}
                }
            },
            "description": "Array of tasks to create (batch_create only)"
        }))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "management action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        if !VALID_ACTIONS.contains(&action.as_str()) {
            return Ok(error_result(format!(
                "Invalid action: \"{action}\". Valid actions: {}",
                VALID_ACTIONS.join(", ")
            )));
        }

        match self.handle_action(&action, params.clone()) {
            Ok(result) => {
                let output =
                    serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string());
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(output),
                    ]),
                    details: Some(json!({"action": action})),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("TaskManager error: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::ConnectionConfig;
    use crate::tools::testutil::{extract_text, make_ctx};

    fn setup_pool() -> Arc<ConnectionPool> {
        let pool = crate::events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        Arc::new(pool)
    }

    #[tokio::test]
    async fn task_manager_create_action() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool
            .execute(json!({"action": "create", "title": "Test"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Test"));
    }

    #[tokio::test]
    async fn task_manager_list_action() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("count"));
    }

    #[tokio::test]
    async fn task_manager_update_action() {
        let pool = setup_pool();
        let tool = TaskManagerTool::new(pool);
        let create_r = tool
            .execute(json!({"action": "create", "title": "Original"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&create_r);
        let created: Value = serde_json::from_str(&text).unwrap();
        let task_id = created["id"].as_str().unwrap();

        let r = tool
            .execute(
                json!({"action": "update", "taskId": task_id, "title": "Updated"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Updated"));
    }

    #[tokio::test]
    async fn task_manager_delete_action() {
        let pool = setup_pool();
        let tool = TaskManagerTool::new(pool);
        let create_r = tool
            .execute(json!({"action": "create", "title": "To Delete"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&create_r);
        let created: Value = serde_json::from_str(&text).unwrap();
        let task_id = created["id"].as_str().unwrap();

        let r = tool
            .execute(json!({"action": "delete", "taskId": task_id}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("success"));
    }

    #[tokio::test]
    async fn task_manager_get_action() {
        let pool = setup_pool();
        let tool = TaskManagerTool::new(pool);
        let create_r = tool
            .execute(json!({"action": "create", "title": "Get Me"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&create_r);
        let created: Value = serde_json::from_str(&text).unwrap();
        let task_id = created["id"].as_str().unwrap();

        let r = tool
            .execute(json!({"action": "get", "taskId": task_id}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("Get Me"));
    }

    #[tokio::test]
    async fn task_manager_search_action() {
        let pool = setup_pool();
        let tool = TaskManagerTool::new(pool);
        let _ = tool
            .execute(json!({"action": "create", "title": "Authentication bug"}), &make_ctx())
            .await
            .unwrap();

        let r = tool
            .execute(json!({"action": "search", "query": "authentication"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn task_manager_unknown_action_errors() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool
            .execute(json!({"action": "unknown"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn task_manager_missing_required_field_errors() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool
            .execute(json!({"action": "get"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn all_actions_dispatch() {
        let pool = setup_pool();
        let tool = TaskManagerTool::new(pool.clone());
        // Create a task for actions that need one
        let create_r = tool
            .execute(json!({"action": "create", "title": "Test"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&create_r);
        let created: Value = serde_json::from_str(&text).unwrap();
        let task_id = created["id"].as_str().unwrap();

        // Most actions need at least some params
        for (action, extra) in [
            ("list", json!({})),
            ("get", json!({"taskId": task_id})),
            ("done", json!({"taskId": task_id})),
            ("search", json!({"query": "test"})),
        ] {
            let mut params = extra;
            params.as_object_mut().unwrap().insert("action".into(), json!(action));
            let r = tool.execute(params, &make_ctx()).await.unwrap();
            assert!(r.is_error.is_none(), "Action {action} failed");
        }
    }

    #[tokio::test]
    async fn missing_action_error() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_action_error() {
        let tool = TaskManagerTool::new(setup_pool());
        let r = tool
            .execute(json!({"action": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid action"));
    }

    #[tokio::test]
    async fn removed_actions_rejected() {
        let tool = TaskManagerTool::new(setup_pool());
        for action in ["create_project", "log_time", "batch_delete", "list_areas"] {
            let r = tool
                .execute(json!({"action": action}), &make_ctx())
                .await
                .unwrap();
            assert_eq!(r.is_error, Some(true), "Action {action} should be invalid");
        }
    }
}
