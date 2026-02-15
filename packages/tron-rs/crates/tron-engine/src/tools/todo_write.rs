use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::Mutex;
use tron_core::ids::SessionId;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

/// A single task item.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct TaskItem {
    pub id: String,
    pub content: String,
    pub status: TaskStatus,
    pub created_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    InProgress,
    Completed,
}

/// Shared task store for a session.
#[derive(Clone, Default)]
pub struct TaskStore {
    inner: Arc<Mutex<HashMap<SessionId, Vec<TaskItem>>>>,
}

impl TaskStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn get_tasks(&self, session_id: &SessionId) -> Vec<TaskItem> {
        let guard = self.inner.lock().await;
        guard.get(session_id).cloned().unwrap_or_default()
    }

    pub async fn set_tasks(&self, session_id: &SessionId, tasks: Vec<TaskItem>) {
        let mut guard = self.inner.lock().await;
        guard.insert(session_id.clone(), tasks);
    }
}

/// TodoWrite tool — manages a task list for the session.
pub struct TodoWriteTool {
    store: TaskStore,
}

impl TodoWriteTool {
    pub fn new(store: TaskStore) -> Self {
        Self { store }
    }
}

#[async_trait]
impl Tool for TodoWriteTool {
    fn name(&self) -> &str {
        "TodoWrite"
    }

    fn description(&self) -> &str {
        "Create and manage a task list for the current session"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["tasks"],
            "properties": {
                "tasks": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "id": { "type": "string" },
                            "content": { "type": "string" },
                            "status": {
                                "type": "string",
                                "enum": ["pending", "in_progress", "completed"]
                            }
                        },
                        "required": ["id", "content", "status"]
                    },
                    "description": "The full task list to write"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Sequential
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let tasks_value = args["tasks"]
            .as_array()
            .ok_or_else(|| ToolError::InvalidArguments("tasks array is required".into()))?;

        let now = chrono::Utc::now().to_rfc3339();
        let mut tasks = Vec::new();

        for item in tasks_value {
            let id = item["id"]
                .as_str()
                .ok_or_else(|| ToolError::InvalidArguments("task id is required".into()))?
                .to_string();

            let content = item["content"]
                .as_str()
                .ok_or_else(|| ToolError::InvalidArguments("task content is required".into()))?
                .to_string();

            let status_str = item["status"]
                .as_str()
                .ok_or_else(|| ToolError::InvalidArguments("task status is required".into()))?;

            let status = match status_str {
                "pending" => TaskStatus::Pending,
                "in_progress" => TaskStatus::InProgress,
                "completed" => TaskStatus::Completed,
                other => {
                    return Err(ToolError::InvalidArguments(format!(
                        "invalid status: {other}"
                    )))
                }
            };

            tasks.push(TaskItem {
                id,
                content,
                status,
                created_at: now.clone(),
            });
        }

        let count = tasks.len();
        self.store.set_tasks(&ctx.session_id, tasks).await;

        Ok(ToolResult {
            content: format!("Task list updated ({count} items)"),
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::AgentId;
    use tokio_util::sync::CancellationToken;

    fn test_ctx() -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: std::env::temp_dir(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[test]
    fn tool_metadata() {
        let store = TaskStore::new();
        let tool = TodoWriteTool::new(store);
        assert_eq!(tool.name(), "TodoWrite");
        assert_eq!(tool.execution_mode(), ExecutionMode::Sequential);
    }

    #[tokio::test]
    async fn write_tasks() {
        let store = TaskStore::new();
        let tool = TodoWriteTool::new(store.clone());
        let ctx = test_ctx();

        let result = tool
            .execute(
                serde_json::json!({
                    "tasks": [
                        {"id": "1", "content": "Write tests", "status": "pending"},
                        {"id": "2", "content": "Fix bug", "status": "in_progress"}
                    ]
                }),
                &ctx,
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("2 items"));

        let tasks = store.get_tasks(&ctx.session_id).await;
        assert_eq!(tasks.len(), 2);
        assert_eq!(tasks[0].content, "Write tests");
        assert_eq!(tasks[0].status, TaskStatus::Pending);
        assert_eq!(tasks[1].status, TaskStatus::InProgress);
    }

    #[tokio::test]
    async fn missing_tasks() {
        let store = TaskStore::new();
        let tool = TodoWriteTool::new(store);
        let result = tool.execute(serde_json::json!({}), &test_ctx()).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn invalid_status() {
        let store = TaskStore::new();
        let tool = TodoWriteTool::new(store);
        let result = tool
            .execute(
                serde_json::json!({
                    "tasks": [{"id": "1", "content": "Test", "status": "invalid"}]
                }),
                &test_ctx(),
            )
            .await;
        assert!(result.is_err());
    }
}
