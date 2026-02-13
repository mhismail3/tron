//! `NotifyApp` tool — sends push notifications to the iOS app.
//!
//! Validates parameters and delegates the actual push to the [`NotifyDelegate`]
//! trait. Title and body are truncated if they exceed recommended limits.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{Notification, NotifyDelegate, ToolContext, TronTool};
use crate::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

const MAX_TITLE_LENGTH: usize = 50;
const MAX_BODY_LENGTH: usize = 200;

/// The `NotifyApp` tool sends push notifications to the iOS app.
pub struct NotifyAppTool {
    delegate: Arc<dyn NotifyDelegate>,
}

impl NotifyAppTool {
    /// Create a new `NotifyApp` tool with the given notification delegate.
    pub fn new(delegate: Arc<dyn NotifyDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for NotifyAppTool {
    fn name(&self) -> &str {
        "NotifyApp"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "NotifyApp".into(),
            description: "Send a push notification to the iOS app.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("title".into(), json!({"type": "string", "description": "Notification title (max 50 chars)"}));
                    let _ = m.insert("body".into(), json!({"type": "string", "description": "Notification body (max 200 chars)"}));
                    let _ = m.insert("priority".into(), json!({"type": "string", "enum": ["high", "normal"], "description": "Notification priority"}));
                    let _ = m.insert("badge".into(), json!({"type": "number", "description": "Badge count on app icon"}));
                    let _ = m.insert("sheetContent".into(), json!({"type": "string", "description": "Markdown content shown on tap"}));
                    let _ = m.insert("data".into(), json!({"type": "object", "description": "Custom data payload"}));
                    m
                }),
                required: Some(vec!["title".into(), "body".into()]),
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
        let title = match validate_required_string(&params, "title", "notification title") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };
        let body = match validate_required_string(&params, "body", "notification body") {
            Ok(b) => b,
            Err(e) => return Ok(e),
        };

        // Truncate to limits
        let title = if title.len() > MAX_TITLE_LENGTH {
            format!("{}...", &title[..MAX_TITLE_LENGTH - 3])
        } else {
            title
        };
        let body = if body.len() > MAX_BODY_LENGTH {
            format!("{}...", &body[..MAX_BODY_LENGTH - 3])
        } else {
            body
        };

        let priority = get_optional_string(&params, "priority").unwrap_or_else(|| "normal".into());
        #[allow(clippy::cast_possible_truncation)]
        let badge = get_optional_u64(&params, "badge").map(|b| b as u32);
        let sheet_content = params.get("sheetContent").cloned();
        let data = params.get("data").cloned();

        let notification = Notification {
            title: title.clone(),
            body: body.clone(),
            priority: priority.clone(),
            badge,
            sheet_content,
            data,
        };

        match self.delegate.send_notification(&notification).await {
            Ok(result) => {
                let msg = if result.success { "Notification sent successfully" } else { "Notification delivery failed" };
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(msg),
                    ]),
                    details: Some(json!({
                        "title": title,
                        "body": body,
                        "priority": priority,
                        "success": result.success,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("Notification failed: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::NotifyResult;

    struct MockNotify {
        result: NotifyResult,
    }

    impl MockNotify {
        fn success() -> Self {
            Self { result: NotifyResult { success: true } }
        }
    }

    #[async_trait]
    impl NotifyDelegate for MockNotify {
        async fn send_notification(&self, _notification: &Notification) -> Result<NotifyResult, ToolError> {
            Ok(self.result.clone())
        }
        async fn open_url_in_app(&self, _url: &str) -> Result<(), ToolError> {
            Ok(())
        }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks.iter().filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                _ => None,
            }).collect::<Vec<_>>().join(""),
        }
    }

    #[tokio::test]
    async fn valid_notification_success() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"title": "Hello", "body": "World"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("successfully"));
    }

    #[tokio::test]
    async fn title_truncated() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let long_title = "x".repeat(100);
        let r = tool.execute(json!({"title": long_title, "body": "b"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert!(d["title"].as_str().unwrap().len() <= MAX_TITLE_LENGTH);
    }

    #[tokio::test]
    async fn body_truncated() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let long_body = "x".repeat(500);
        let r = tool.execute(json!({"title": "t", "body": long_body}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert!(d["body"].as_str().unwrap().len() <= MAX_BODY_LENGTH);
    }

    #[tokio::test]
    async fn priority_high() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"title": "t", "body": "b", "priority": "high"}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["priority"], "high");
    }

    #[tokio::test]
    async fn priority_default_normal() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"title": "t", "body": "b"}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["priority"], "normal");
    }

    #[tokio::test]
    async fn badge_passed() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"title": "t", "body": "b", "badge": 5}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn missing_title_error() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"body": "b"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_body_error() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool.execute(json!({"title": "t"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
