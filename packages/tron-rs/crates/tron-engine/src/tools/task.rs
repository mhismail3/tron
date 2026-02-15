use async_trait::async_trait;
use std::time::Instant;
use tokio::sync::oneshot;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

/// Callback type for spawning subagents. The server/engine layer provides this.
/// Returns a receiver that resolves when the subagent completes.
pub type SubagentSpawner =
    Box<dyn Fn(SubagentRequest) -> oneshot::Receiver<SubagentResult> + Send + Sync>;

/// Request to spawn a subagent.
#[derive(Debug, Clone)]
pub struct SubagentRequest {
    pub prompt: String,
    pub description: String,
    pub parent_agent_id: tron_core::ids::AgentId,
    pub parent_session_id: tron_core::ids::SessionId,
    pub max_turns: Option<u32>,
}

/// Result from a completed subagent.
#[derive(Debug, Clone)]
pub struct SubagentResult {
    pub content: String,
    pub is_error: bool,
}

/// Task tool — spawns a subagent to handle complex tasks autonomously.
pub struct TaskTool {
    spawner: std::sync::Arc<SubagentSpawner>,
}

impl TaskTool {
    pub fn new(spawner: SubagentSpawner) -> Self {
        Self {
            spawner: std::sync::Arc::new(spawner),
        }
    }

    /// Create a tool that always returns an error (no subagent manager available).
    pub fn unavailable() -> Self {
        Self {
            spawner: std::sync::Arc::new(Box::new(|_| {
                let (tx, rx) = oneshot::channel();
                tx.send(SubagentResult {
                    content: "Subagent spawning is not available".into(),
                    is_error: true,
                })
                .ok();
                rx
            })),
        }
    }
}

#[async_trait]
impl Tool for TaskTool {
    fn name(&self) -> &str {
        "Task"
    }

    fn description(&self) -> &str {
        "Launch an autonomous subagent to handle a complex task"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["prompt", "description"],
            "properties": {
                "prompt": {
                    "type": "string",
                    "description": "The task for the subagent to perform"
                },
                "description": {
                    "type": "string",
                    "description": "A short (3-5 word) description of the task"
                },
                "max_turns": {
                    "type": "integer",
                    "description": "Maximum turns for the subagent (default: 25)"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Concurrent
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let prompt = args["prompt"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("prompt is required".into()))?
            .to_string();

        let description = args["description"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("description is required".into()))?
            .to_string();

        let max_turns = args["max_turns"].as_u64().map(|n| n as u32);

        let request = SubagentRequest {
            prompt,
            description,
            parent_agent_id: ctx.agent_id.clone(),
            parent_session_id: ctx.session_id.clone(),
            max_turns,
        };

        let rx = (self.spawner)(request);

        let result = rx.await.map_err(|_| {
            ToolError::ExecutionFailed("Subagent channel closed unexpectedly".into())
        })?;

        Ok(ToolResult {
            content: result.content,
            is_error: result.is_error,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId};
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
        let tool = TaskTool::unavailable();
        assert_eq!(tool.name(), "Task");
        assert_eq!(tool.execution_mode(), ExecutionMode::Concurrent);

        let schema = tool.parameters_schema();
        let required = schema["required"].as_array().unwrap();
        assert!(required.iter().any(|v| v == "prompt"));
        assert!(required.iter().any(|v| v == "description"));
    }

    #[tokio::test]
    async fn missing_prompt() {
        let tool = TaskTool::unavailable();
        let result = tool
            .execute(
                serde_json::json!({"description": "test"}),
                &test_ctx(),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn unavailable_returns_error() {
        let tool = TaskTool::unavailable();
        let result = tool
            .execute(
                serde_json::json!({"prompt": "Do something", "description": "test task"}),
                &test_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error);
        assert!(result.content.contains("not available"));
    }

    #[tokio::test]
    async fn successful_subagent() {
        let spawner: SubagentSpawner = Box::new(|req: SubagentRequest| {
            let (tx, rx) = oneshot::channel();
            assert!(req.prompt.contains("find files"));
            tx.send(SubagentResult {
                content: "Found 3 matching files".into(),
                is_error: false,
            })
            .ok();
            rx
        });

        let tool = TaskTool::new(spawner);
        let result = tool
            .execute(
                serde_json::json!({
                    "prompt": "find files matching *.rs",
                    "description": "search rust files"
                }),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert_eq!(result.content, "Found 3 matching files");
    }
}
