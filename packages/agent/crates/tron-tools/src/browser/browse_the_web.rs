//! `BrowseTheWeb` tool — CDP-based browser automation.
//!
//! Routes browser actions to the [`BrowserDelegate`] trait. Supports 18 actions
//! across navigation, observation, interaction, waiting, scrolling, and export.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{BrowserAction, BrowserDelegate, ExecutionMode, ToolContext, TronTool};
use crate::utils::validation::validate_required_string;

const VALID_ACTIONS: &[&str] = &[
    "navigate",
    "goBack",
    "goForward",
    "reload",
    "snapshot",
    "screenshot",
    "click",
    "fill",
    "type",
    "select",
    "hover",
    "pressKey",
    "wait",
    "scroll",
    "getText",
    "getAttribute",
    "pdf",
    "close",
];

/// The `BrowseTheWeb` tool provides full browser automation via a delegate.
pub struct BrowseTheWebTool {
    delegate: Arc<dyn BrowserDelegate>,
}

impl BrowseTheWebTool {
    /// Create a new `BrowseTheWeb` tool with the given browser delegate.
    pub fn new(delegate: Arc<dyn BrowserDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for BrowseTheWebTool {
    fn name(&self) -> &str {
        "BrowseTheWeb"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Serialized("browser".into())
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "BrowseTheWeb".into(),
            description: "Control a web browser with automation capabilities.\n\n\
IMPORTANT: Execute browser actions ONE AT A TIME sequentially — wait for each action to complete \
before starting the next. Do NOT call multiple browser tools in parallel as this causes race conditions.\n\n\
Recommended workflow:\n\
1. navigate to URL → wait for result\n\
2. snapshot to get page structure → wait for result\n\
3. screenshot to see visual state → wait for result\n\
4. interact (click/fill/etc.) → wait for result\n\n\
Actions:\n\
- navigate: Go to a URL. Required: url\n\
- snapshot: Get accessibility tree with element references (call AFTER navigate)\n\
- screenshot: Capture visual screenshot of current viewport\n\
- click: Click an element. Required: selector (CSS or element ref e.g. \"e1\")\n\
- fill: Fill an input field. Required: selector, value\n\
- type: Type text character by character. Required: selector, text\n\
- select: Select dropdown option(s). Required: selector, value\n\
- wait: Wait for element or timeout. Optional: selector, timeout (ms)\n\
- scroll: Scroll page or element. Required: direction (up/down/left/right). Optional: amount (px)\n\
- goBack / goForward / reload: Navigation history\n\
- hover: Hover over an element. Required: selector\n\
- pressKey: Press a keyboard key. Required: key (e.g. \"Enter\", \"Tab\")\n\
- getText: Get text from element. Required: selector\n\
- getAttribute: Get attribute value. Required: selector, attribute\n\
- pdf: Generate PDF. Optional: path\n\
- close: Close browser session\n\n\
Element references from snapshot (e1, e2) are automatically resolved. \
Browser sessions are persistent — once created, you can perform multiple actions.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("action".into(), json!({
                        "type": "string",
                        "enum": VALID_ACTIONS,
                        "description": "Browser action to perform"
                    }));
                    let _ = m.insert("url".into(), json!({"type": "string", "description": "URL for navigate action"}));
                    let _ = m.insert("selector".into(), json!({"type": "string", "description": "CSS selector or element reference"}));
                    let _ = m.insert("value".into(), json!({"type": "string", "description": "Value for fill or select actions"}));
                    let _ = m.insert("text".into(), json!({"type": "string", "description": "Text for type action"}));
                    let _ = m.insert("direction".into(), json!({"type": "string", "description": "Scroll direction: up, down, left, right"}));
                    let _ = m.insert("amount".into(), json!({"type": "number", "description": "Scroll amount in pixels"}));
                    let _ = m.insert("timeout".into(), json!({"type": "number", "description": "Timeout in milliseconds for wait action"}));
                    let _ = m.insert("key".into(), json!({"type": "string", "description": "Key name for pressKey (e.g., Enter, Tab)"}));
                    let _ = m.insert("attribute".into(), json!({"type": "string", "description": "Attribute name for getAttribute"}));
                    let _ = m.insert("path".into(), json!({"type": "string", "description": "File path for pdf action"}));
                    m
                }),
                required: Some(vec!["action".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let action_name = match validate_required_string(&params, "action", "browser action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        if !VALID_ACTIONS.contains(&action_name.as_str()) {
            return Ok(error_result(format!(
                "Invalid action: \"{action_name}\". Valid actions: {}",
                VALID_ACTIONS.join(", ")
            )));
        }

        // Handle close action specially — delegates to close_session
        if action_name == "close" {
            return match self.delegate.close_session(&ctx.session_id).await {
                Ok(()) => Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text("Browser session closed"),
                    ]),
                    details: Some(json!({"action": "close"})),
                    is_error: None,
                    stop_turn: None,
                }),
                Err(e) => Ok(error_result(format!("Failed to close browser: {e}"))),
            };
        }

        // Build BrowserAction from params
        let browser_action = BrowserAction {
            action: action_name.clone(),
            params: params.clone(),
        };

        match self
            .delegate
            .execute_action(&ctx.session_id, &browser_action)
            .await
        {
            Ok(result) => Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![tron_core::content::ToolResultContent::text(
                    &result.content,
                )]),
                details: result.details,
                is_error: None,
                stop_turn: None,
            }),
            Err(e) => Ok(error_result(format!("Browser action failed: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{BrowserResult, ExecutionMode};
    use std::sync::Mutex;

    struct MockBrowser {
        last_action: Mutex<Option<String>>,
        should_fail: bool,
    }

    impl MockBrowser {
        fn success() -> Self {
            Self {
                last_action: Mutex::new(None),
                should_fail: false,
            }
        }

        fn failing() -> Self {
            Self {
                last_action: Mutex::new(None),
                should_fail: true,
            }
        }
    }

    #[async_trait]
    impl BrowserDelegate for MockBrowser {
        async fn execute_action(
            &self,
            _session_id: &str,
            action: &BrowserAction,
        ) -> Result<BrowserResult, ToolError> {
            *self.last_action.lock().unwrap() = Some(action.action.clone());
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "browser error".into(),
                });
            }
            Ok(BrowserResult {
                content: format!("Action {} executed", action.action),
                details: Some(json!({"action": action.action})),
            })
        }

        async fn close_session(&self, _session_id: &str) -> Result<(), ToolError> {
            *self.last_action.lock().unwrap() = Some("close".into());
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "close error".into(),
                });
            }
            Ok(())
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

    #[test]
    fn browse_the_web_execution_mode() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        assert_eq!(
            tool.execution_mode(),
            ExecutionMode::Serialized("browser".into())
        );
    }

    #[tokio::test]
    async fn navigate_action() {
        let delegate = Arc::new(MockBrowser::success());
        let tool = BrowseTheWebTool::new(delegate.clone());
        let r = tool
            .execute(
                json!({"action": "navigate", "url": "https://example.com"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert_eq!(
            *delegate.last_action.lock().unwrap(),
            Some("navigate".into())
        );
    }

    #[tokio::test]
    async fn snapshot_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "snapshot"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("snapshot"));
    }

    #[tokio::test]
    async fn screenshot_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "screenshot"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn click_action_with_selector() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "click", "selector": "button.submit"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn fill_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "fill", "selector": "#name", "value": "test"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn type_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "type", "selector": "#search", "text": "hello"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn select_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "select", "selector": "#country", "value": "US"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn hover_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "hover", "selector": ".menu-item"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn press_key_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "pressKey", "key": "Enter"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn wait_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "wait", "selector": "#loading", "timeout": 5000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn scroll_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "scroll", "direction": "down", "amount": 500}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn get_text_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "getText", "selector": "h1"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn get_attribute_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "getAttribute", "selector": "img", "attribute": "src"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn pdf_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(
                json!({"action": "pdf", "path": "/tmp/out.pdf"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn close_action() {
        let delegate = Arc::new(MockBrowser::success());
        let tool = BrowseTheWebTool::new(delegate.clone());
        let r = tool
            .execute(json!({"action": "close"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("closed"));
        assert_eq!(*delegate.last_action.lock().unwrap(), Some("close".into()));
    }

    #[tokio::test]
    async fn all_actions_dispatch() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        for action in VALID_ACTIONS {
            let r = tool
                .execute(json!({"action": action}), &make_ctx())
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "Action {action} returned error");
        }
    }

    #[tokio::test]
    async fn missing_action_error() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_action_error() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid action"));
    }

    #[tokio::test]
    async fn delegate_error() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::failing()));
        let r = tool
            .execute(
                json!({"action": "navigate", "url": "https://example.com"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Browser action failed"));
    }

    #[tokio::test]
    async fn close_delegate_error() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::failing()));
        let r = tool
            .execute(json!({"action": "close"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Failed to close"));
    }

    #[tokio::test]
    async fn go_back_and_forward() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r1 = tool
            .execute(json!({"action": "goBack"}), &make_ctx())
            .await
            .unwrap();
        assert!(r1.is_error.is_none());
        let r2 = tool
            .execute(json!({"action": "goForward"}), &make_ctx())
            .await
            .unwrap();
        assert!(r2.is_error.is_none());
    }

    #[tokio::test]
    async fn reload_action() {
        let tool = BrowseTheWebTool::new(Arc::new(MockBrowser::success()));
        let r = tool
            .execute(json!({"action": "reload"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }
}
