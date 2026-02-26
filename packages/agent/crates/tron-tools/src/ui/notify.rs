//! `NotifyApp` tool — sends push notifications to the iOS app.
//!
//! Validates parameters and delegates the actual push to the [`NotifyDelegate`]
//! trait. Title and body are truncated if they exceed recommended limits.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{Notification, NotifyDelegate, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
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
        ToolSchemaBuilder::new(
            "NotifyApp",
            "Send a push notification to the Tron iOS app. The user is often away — notify proactively and liberally.\n\n\
## When to Use\n\
- Task completed or milestone reached\n\
- Error, failure, or blocker encountered\n\
- User input or decision needed\n\
- Interesting finding worth sharing\n\
- Build/test results ready\n\
- Starting a long operation\n\
- Session is idle and waiting\n\n\
## Guidelines\n\
- Default to sending — a dismissed notification costs nothing, a missed one costs context\n\
- Keep titles concise (max 50 chars)\n\
- Keep body text brief (max 200 chars)\n\
- Use high priority for errors or blockers needing immediate attention\n\
- Send notifications as events happen, don't batch them",
        )
        .required_property("title", json!({"type": "string", "description": "Notification title (max 50 chars)"}))
        .required_property("body", json!({"type": "string", "description": "Notification body (max 200 chars)"}))
        .property("priority", json!({"type": "string", "enum": ["high", "normal"], "description": "Notification priority"}))
        .property("badge", json!({"type": "number", "description": "Badge count on app icon"}))
        .property("sheetContent", json!({"type": "string", "description": "Markdown content shown on tap"}))
        .property("data", json!({"type": "object", "description": "Custom data payload"}))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let title = match validate_required_string(&params, "title", "notification title") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };
        let body = match validate_required_string(&params, "body", "notification body") {
            Ok(b) => b,
            Err(e) => return Ok(e),
        };

        // Truncate to limits (UTF-8–safe)
        let title = tron_core::text::truncate_with_suffix(&title, MAX_TITLE_LENGTH, "...");
        let body = tron_core::text::truncate_with_suffix(&body, MAX_BODY_LENGTH, "...");

        let priority = get_optional_string(&params, "priority").unwrap_or_else(|| "normal".into());
        #[allow(clippy::cast_possible_truncation)]
        let badge = get_optional_u64(&params, "badge").map(|b| b as u32);
        let sheet_content = params.get("sheetContent").cloned();

        // Auto-inject session context into data payload so every push
        // notification carries reliable session/tool-call IDs regardless
        // of what the LLM passes in the data field.
        let data = {
            let mut obj = params
                .get("data")
                .and_then(|v| v.as_object().cloned())
                .unwrap_or_default();
            obj.insert("sessionId".into(), Value::String(ctx.session_id.clone()));
            obj.insert(
                "toolCallId".into(),
                Value::String(ctx.tool_call_id.clone()),
            );
            Some(Value::Object(obj))
        };

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
                let msg = if result.success {
                    result.message.as_deref().map_or_else(
                        || "Notification sent successfully".to_string(),
                        String::from,
                    )
                } else {
                    result.message.as_deref().map_or_else(
                        || "Notification delivery failed".to_string(),
                        |m| format!("Notification delivery failed. {m}"),
                    )
                };
                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(&msg),
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
    use crate::testutil::{extract_text, make_ctx};
    use crate::traits::NotifyResult;

    use std::sync::Mutex;

    struct MockNotify {
        result: NotifyResult,
        last_notification: Mutex<Option<Notification>>,
    }

    impl MockNotify {
        fn success() -> Self {
            Self {
                result: NotifyResult {
                    success: true,
                    message: None,
                },
                last_notification: Mutex::new(None),
            }
        }

        fn last_notification(&self) -> Option<Notification> {
            self.last_notification.lock().unwrap().clone()
        }
    }

    #[async_trait]
    impl NotifyDelegate for MockNotify {
        async fn send_notification(
            &self,
            notification: &Notification,
        ) -> Result<NotifyResult, ToolError> {
            *self.last_notification.lock().unwrap() = Some(notification.clone());
            Ok(self.result.clone())
        }
        async fn open_url_in_app(&self, _url: &str) -> Result<(), ToolError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn valid_notification_success() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"title": "Hello", "body": "World"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("successfully"));
    }

    #[tokio::test]
    async fn title_truncated() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let long_title = "x".repeat(100);
        let r = tool
            .execute(json!({"title": long_title, "body": "b"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["title"].as_str().unwrap().len() <= MAX_TITLE_LENGTH);
    }

    #[tokio::test]
    async fn body_truncated() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let long_body = "x".repeat(500);
        let r = tool
            .execute(json!({"title": "t", "body": long_body}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["body"].as_str().unwrap().len() <= MAX_BODY_LENGTH);
    }

    #[tokio::test]
    async fn priority_high() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(
                json!({"title": "t", "body": "b", "priority": "high"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["priority"], "high");
    }

    #[tokio::test]
    async fn priority_default_normal() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"title": "t", "body": "b"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["priority"], "normal");
    }

    #[tokio::test]
    async fn badge_passed() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"title": "t", "body": "b", "badge": 5}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn missing_title_error() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"body": "b"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_body_error() {
        let tool = NotifyAppTool::new(Arc::new(MockNotify::success()));
        let r = tool
            .execute(json!({"title": "t"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn session_id_injected_into_notification_data() {
        let mock = Arc::new(MockNotify::success());
        let tool = NotifyAppTool::new(mock.clone());
        let ctx = make_ctx();
        tool.execute(json!({"title": "t", "body": "b"}), &ctx)
            .await
            .unwrap();
        let notif = mock.last_notification().unwrap();
        let data = notif.data.unwrap();
        assert_eq!(data["sessionId"], ctx.session_id);
    }

    #[tokio::test]
    async fn tool_call_id_injected_into_notification_data() {
        let mock = Arc::new(MockNotify::success());
        let tool = NotifyAppTool::new(mock.clone());
        let ctx = make_ctx();
        tool.execute(json!({"title": "t", "body": "b"}), &ctx)
            .await
            .unwrap();
        let notif = mock.last_notification().unwrap();
        let data = notif.data.unwrap();
        assert_eq!(data["toolCallId"], ctx.tool_call_id);
    }

    #[tokio::test]
    async fn existing_data_preserved_with_injected_fields() {
        let mock = Arc::new(MockNotify::success());
        let tool = NotifyAppTool::new(mock.clone());
        let ctx = make_ctx();
        tool.execute(
            json!({"title": "t", "body": "b", "data": {"custom": "value"}}),
            &ctx,
        )
        .await
        .unwrap();
        let notif = mock.last_notification().unwrap();
        let data = notif.data.unwrap();
        assert_eq!(data["custom"], "value");
        assert_eq!(data["sessionId"], ctx.session_id);
        assert_eq!(data["toolCallId"], ctx.tool_call_id);
    }

    #[tokio::test]
    async fn no_data_creates_new_map_with_injected_fields() {
        let mock = Arc::new(MockNotify::success());
        let tool = NotifyAppTool::new(mock.clone());
        let ctx = make_ctx();
        tool.execute(json!({"title": "t", "body": "b"}), &ctx)
            .await
            .unwrap();
        let notif = mock.last_notification().unwrap();
        let data = notif.data.unwrap();
        let obj = data.as_object().unwrap();
        assert_eq!(obj.len(), 2);
        assert!(obj.contains_key("sessionId"));
        assert!(obj.contains_key("toolCallId"));
    }
}
