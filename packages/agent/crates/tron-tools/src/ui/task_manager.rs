//! `TaskManager` tool — task/project/area management.
//!
//! Routes management actions to the [`TaskManagerDelegate`] trait. Supports
//! 18 actions across tasks, projects, and areas.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{TaskManagerDelegate, ToolContext, TronTool};
use crate::utils::validation::validate_required_string;

const VALID_ACTIONS: &[&str] = &[
    "create",
    "update",
    "get",
    "list",
    "search",
    "log_time",
    "delete",
    "create_project",
    "update_project",
    "get_project",
    "list_projects",
    "delete_project",
    "create_area",
    "update_area",
    "get_area",
    "delete_area",
    "list_areas",
];

/// The `TaskManager` tool manages tasks, projects, and areas.
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
        Tool {
            name: "TaskManager".into(),
            description: "Persistent task, project, and area manager (PARA model). Tasks survive across sessions.\n\n\
## PARA Model\n\
- **Projects**: Time-bound scoped efforts with tasks\n\
- **Areas**: Ongoing responsibilities the agent maintains awareness of (e.g., \"Security\", \"Code Quality\")\n\
- **Tasks**: Individual work items, optionally linked to a project and/or area\n\n\
## Actions\n\n\
### Tasks\n\
- **create**: Create a task. Required: title. Optional: description, status, priority, projectId, areaId\n\
- **update**: Update a task. Required: taskId. Optional: status, title, description, priority, projectId, areaId\n\
- **get**: Get task details. Required: taskId\n\
- **list**: List tasks. Optional: filter by status/priority/projectId/areaId, limit, offset\n\
- **search**: Full-text search. Required: query. Optional: limit\n\
- **log_time**: Log time spent. Required: taskId, minutes\n\
- **delete**: Delete a task. Required: taskId\n\n\
### Projects\n\
- **create_project**: Required: projectTitle. Optional: projectDescription, areaId\n\
- **update_project**: Required: projectId. Optional: projectTitle, projectDescription, projectStatus, areaId\n\
- **get_project**: Get project details with tasks. Required: projectId\n\
- **delete_project**: Delete project (orphans tasks). Required: projectId\n\
- **list_projects**: List projects. Optional: filter by status/areaId\n\n\
### Areas\n\
- **create_area**: Required: areaTitle. Optional: areaDescription\n\
- **update_area**: Required: areaId. Optional: areaTitle, areaDescription, areaStatus\n\
- **get_area** / **delete_area** / **list_areas**\n\n\
## Status Model\n\
backlog → pending → in_progress → completed/cancelled\n\n\
## Key Behaviors\n\
- status→in_progress auto-sets startedAt; status→completed auto-sets completedAt\n\
- notes append with timestamps (never replace)\n\
- Dependencies: addBlocks/addBlockedBy create blocking relationships; circular deps rejected".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("action".into(), json!({
                        "type": "string",
                        "enum": VALID_ACTIONS,
                        "description": "The management action to perform"
                    }));
                    let _ = m.insert("taskId".into(), json!({"type": "string"}));
                    let _ = m.insert("title".into(), json!({"type": "string"}));
                    let _ = m.insert("description".into(), json!({"type": "string"}));
                    let _ = m.insert("status".into(), json!({"type": "string"}));
                    let _ = m.insert("priority".into(), json!({"type": "string"}));
                    let _ = m.insert("projectId".into(), json!({"type": "string"}));
                    let _ = m.insert("areaId".into(), json!({"type": "string"}));
                    let _ = m.insert("projectTitle".into(), json!({"type": "string"}));
                    let _ = m.insert("areaTitle".into(), json!({"type": "string"}));
                    let _ = m.insert("query".into(), json!({"type": "string"}));
                    let _ = m.insert("limit".into(), json!({"type": "number"}));
                    let _ = m.insert("offset".into(), json!({"type": "number"}));
                    m
                }),
                required: Some(vec!["action".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
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
                        tron_core::content::ToolResultContent::text(output),
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

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks
                .iter()
                .filter_map(|b| match b {
                    tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join(""),
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
    async fn update_action() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "update", "taskId": "t1"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn list_action() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(json!({"action": "list"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
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
    async fn create_project() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(
                json!({"action": "create_project", "projectTitle": "P1"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn create_area() {
        let tool = TaskManagerTool::new(Arc::new(MockDelegate));
        let r = tool
            .execute(
                json!({"action": "create_area", "areaTitle": "A1"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
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
