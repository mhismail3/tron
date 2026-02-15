use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

/// NotifyApp tool — sends a notification to the iOS client (fire-and-forget).
///
/// The notification is sent via the event broadcast channel, which the
/// WebSocket layer picks up and forwards to connected clients.
pub struct NotifyAppTool;

#[async_trait]
impl Tool for NotifyAppTool {
    fn name(&self) -> &str {
        "NotifyApp"
    }

    fn description(&self) -> &str {
        "Send a notification to the connected app (fire-and-forget)"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["message"],
            "properties": {
                "message": {
                    "type": "string",
                    "description": "The notification message"
                },
                "title": {
                    "type": "string",
                    "description": "Optional notification title"
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
        _ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let message = args["message"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("message is required".into()))?;

        let title = args["title"].as_str().unwrap_or("Tron");

        // Fire-and-forget: the notification is logged and the tool returns immediately.
        // The actual delivery to iOS happens via the event bridge when the engine
        // emits a notification event.
        tracing::info!(title = title, message = message, "NotifyApp: sending notification");

        Ok(ToolResult {
            content: format!("Notification sent: {title} — {message}"),
            is_error: false,
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
        let tool = NotifyAppTool;
        assert_eq!(tool.name(), "NotifyApp");
        assert_eq!(tool.execution_mode(), ExecutionMode::Concurrent);
    }

    #[tokio::test]
    async fn notify_with_title() {
        let tool = NotifyAppTool;
        let result = tool
            .execute(
                serde_json::json!({"message": "Build complete", "title": "CI"}),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("CI"));
        assert!(result.content.contains("Build complete"));
    }

    #[tokio::test]
    async fn notify_without_title() {
        let tool = NotifyAppTool;
        let result = tool
            .execute(
                serde_json::json!({"message": "Done"}),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("Tron"));
    }

    #[tokio::test]
    async fn missing_message() {
        let tool = NotifyAppTool;
        let result = tool.execute(serde_json::json!({}), &test_ctx()).await;
        assert!(result.is_err());
    }
}
