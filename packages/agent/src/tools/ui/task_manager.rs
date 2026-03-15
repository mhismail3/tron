//! `TaskManager` tool — persistent task tracker.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{TaskManagerDelegate, ToolContext, TronTool};
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
    delegate: Arc<dyn TaskManagerDelegate>,
}

impl TaskManagerTool {
    /// Create a new `TaskManager` tool with the given delegate.
    pub fn new(delegate: Arc<dyn TaskManagerDelegate>) -> Self {
        Self { delegate }
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

        match self.delegate.execute_action(&action, params.clone()).await {
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
    use crate::tools::testutil::{extract_text, make_ctx};

    struct MockDelegate;

    #[async_trait]
    impl TaskManagerDelegate for MockDelegate {
        async fn execute_action(&self, action: &str, _params: Value) -> Result<Value, ToolError> {
            Ok(json!({"action": action, "success": true}))
        }
    }

    struct ErrorDelegate;

    #[async_trait]
    impl TaskManagerDelegate for ErrorDelegate {
        async fn execute_action(&self, _action: &str, _params: Value) -> Result<Value, ToolError> {
            Err(ToolError::Internal {
                message: "delegate error".into(),
            })
        }
    }

    #[tokio::test]
    async fn create_action() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "create", "title": "Test"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("create"));
    }

    #[tokio::test]
    async fn all_actions_dispatch() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        for action in VALID_ACTIONS {
            let r = tool
                .execute(json!({"action": action}), &make_ctx())
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "Action {action} failed");
        }
    }

    #[tokio::test]
    async fn missing_action_error() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_action_error() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid action"));
    }

    #[tokio::test]
    async fn removed_actions_rejected() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        for action in ["create_project", "log_time", "batch_delete", "list_areas"] {
            let r = tool
                .execute(json!({"action": action}), &make_ctx())
                .await
                .unwrap();
            assert_eq!(r.is_error, Some(true), "Action {action} should be invalid");
        }
    }

    #[tokio::test]
    async fn delegate_error() {
        let tool = TaskManagerTool::new(Arc::new(ErrorDelegate));
        let r = tool
            .execute(json!({"action": "create"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
