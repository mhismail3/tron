use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

/// OpenURL tool — delegates URL opening to the iOS client.
///
/// Like NotifyApp, this is fire-and-forget. The actual opening is handled by
/// the client when it receives the event.
pub struct OpenUrlTool;

#[async_trait]
impl Tool for OpenUrlTool {
    fn name(&self) -> &str {
        "OpenURL"
    }

    fn description(&self) -> &str {
        "Open a URL in the connected app's browser"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["url"],
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to open"
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

        let url = args["url"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("url is required".into()))?;

        // Validate URL format
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err(ToolError::InvalidArguments(format!(
                "invalid URL (must start with http:// or https://): {url}"
            )));
        }

        tracing::info!(url = url, "OpenURL: requesting client to open URL");

        Ok(ToolResult {
            content: format!("Opening URL: {url}"),
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
        let tool = OpenUrlTool;
        assert_eq!(tool.name(), "OpenURL");
        assert_eq!(tool.execution_mode(), ExecutionMode::Concurrent);
    }

    #[tokio::test]
    async fn open_valid_url() {
        let tool = OpenUrlTool;
        let result = tool
            .execute(
                serde_json::json!({"url": "https://example.com"}),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("https://example.com"));
    }

    #[tokio::test]
    async fn reject_invalid_url() {
        let tool = OpenUrlTool;
        let result = tool
            .execute(
                serde_json::json!({"url": "ftp://not-http.com"}),
                &test_ctx(),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn missing_url() {
        let tool = OpenUrlTool;
        let result = tool.execute(serde_json::json!({}), &test_ctx()).await;
        assert!(result.is_err());
    }
}
