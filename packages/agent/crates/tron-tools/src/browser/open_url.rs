//! `OpenURL` tool — opens a URL in the iOS app.
//!
//! Validates the URL (format, protocol) and delegates to [`NotifyDelegate`]
//! to open it in Safari. This is an interactive tool.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{NotifyDelegate, ToolContext, TronTool};
use crate::utils::validation::validate_required_string;

/// The `OpenURL` tool opens a URL in Safari via the iOS app.
pub struct OpenURLTool {
    delegate: Arc<dyn NotifyDelegate>,
}

impl OpenURLTool {
    /// Create a new `OpenURL` tool with the given notification delegate.
    pub fn new(delegate: Arc<dyn NotifyDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for OpenURLTool {
    fn name(&self) -> &str {
        "OpenURL"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "OpenURL".into(),
            description: "Open a URL in the native iOS Safari browser for the user to view.\n\n\
Use this tool when you want to:\n\
- Show the user a webpage, documentation, or article\n\
- Direct the user to a website for reference\n\
- Open external links for the user to explore\n\n\
The URL opens in Safari within the app. The user can browse, interact with the page, \
and dismiss it when done. This is a fire-and-forget action — you don't need to wait \
for the user to close the browser.\n\n\
Examples:\n\
- Open documentation: { \"url\": \"https://docs.swift.org/swift-book/\" }\n\
- Show a reference: { \"url\": \"https://developer.apple.com/documentation/swiftui\" }"
                .into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("url".into(), json!({"type": "string", "description": "The URL to open (must be http:// or https://)"}));
                    m
                }),
                required: Some(vec!["url".into()]),
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
        let url = match validate_required_string(&params, "url", "URL") {
            Ok(u) => u,
            Err(e) => return Ok(e),
        };

        let trimmed = url.trim();
        if trimmed.is_empty() {
            return Ok(error_result("Missing required parameter: url"));
        }

        // Validate URL format
        let Ok(parsed) = url::Url::parse(trimmed) else {
            return Ok(error_result(format!(
                "Invalid URL format: \"{trimmed}\". Please provide a valid URL."
            )));
        };

        // Only allow http and https
        let scheme = parsed.scheme();
        if scheme != "http" && scheme != "https" {
            return Ok(error_result(format!(
                "Invalid URL scheme: \"{scheme}\". Only http:// and https:// URLs are allowed."
            )));
        }

        // Delegate to the app
        if let Err(e) = self.delegate.open_url_in_app(trimmed).await {
            return Ok(error_result(format!("Failed to open URL: {e}")));
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![tron_core::content::ToolResultContent::text(
                format!("Opening {trimmed} in Safari"),
            )]),
            details: Some(json!({
                "url": trimmed,
                "action": "open_safari",
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{Notification, NotifyResult};

    struct MockNotify {
        should_fail: bool,
    }

    impl MockNotify {
        fn success() -> Self {
            Self { should_fail: false }
        }

        fn failing() -> Self {
            Self { should_fail: true }
        }
    }

    #[async_trait]
    impl NotifyDelegate for MockNotify {
        async fn send_notification(
            &self,
            _notification: &Notification,
        ) -> Result<NotifyResult, ToolError> {
            Ok(NotifyResult {
                success: true,
                message: None,
            })
        }

        async fn open_url_in_app(&self, _url: &str) -> Result<(), ToolError> {
            if self.should_fail {
                Err(ToolError::Internal {
                    message: "delegate error".into(),
                })
            } else {
                Ok(())
            }
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
    async fn valid_https_url() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "https://example.com"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Opening"));
        assert!(text.contains("example.com"));
    }

    #[tokio::test]
    async fn valid_http_url_accepted() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "http://example.com"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn details_include_action() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "https://example.com"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["action"], "open_safari");
        assert_eq!(d["url"], "https://example.com");
    }

    #[tokio::test]
    async fn invalid_protocol_ftp() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "ftp://files.example.com"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid URL scheme"));
    }

    #[tokio::test]
    async fn invalid_protocol_javascript() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "javascript:alert(1)"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_url_error() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn empty_url_error() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "  "}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_format_error() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "not a valid url"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid URL format"));
    }

    #[tokio::test]
    async fn is_interactive_returns_true() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        assert!(tool.is_interactive());
    }

    #[tokio::test]
    async fn delegate_error() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::failing()));
        let r = tool
            .execute(json!({"url": "https://example.com"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Failed to open URL"));
    }

    #[tokio::test]
    async fn whitespace_trimmed() {
        let tool = OpenURLTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"url": "  https://example.com  "}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert_eq!(r.details.unwrap()["url"], "https://example.com");
    }
}
