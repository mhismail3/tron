//! `BrowserDelegate` implementation backed by CDP.

use std::sync::Arc;

use crate::errors::ToolError;
use crate::traits::{BrowserAction, BrowserDelegate, BrowserResult};
use async_trait::async_trait;
use serde_json::Value;

use super::service::BrowserService;

/// CDP-backed browser delegate that routes actions to `BrowserSession` via `BrowserService`.
pub struct CdpBrowserDelegate {
    service: Arc<BrowserService>,
}

impl CdpBrowserDelegate {
    /// Create a new delegate wrapping a `BrowserService`.
    pub fn new(service: Arc<BrowserService>) -> Self {
        Self { service }
    }
}

#[async_trait]
#[allow(clippy::too_many_lines)]
impl BrowserDelegate for CdpBrowserDelegate {
    async fn execute_action(
        &self,
        session_id: &str,
        action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError> {
        let session =
            self.service
                .get_or_create(session_id)
                .await
                .map_err(|e| ToolError::Internal {
                    message: e.to_string(),
                })?;

        // Auto-start screencast for iOS frame streaming (matches TS server behavior)
        if !session.is_streaming() {
            if let Err(e) = self.service.start_stream(session_id).await {
                tracing::warn!(session_id, error = %e, "auto-start screencast failed (non-fatal)");
            }
        }

        match action.action.as_str() {
            "navigate" => {
                let url = action
                    .params
                    .get("url")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "navigate requires 'url' parameter".into(),
                    })?;
                session
                    .navigate(url)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Navigated to {url}"),
                    details: None,
                })
            }

            "goBack" => {
                session.go_back().await.map_err(|e| ToolError::Internal {
                    message: e.to_string(),
                })?;
                Ok(BrowserResult {
                    content: "Navigated back".into(),
                    details: None,
                })
            }

            "goForward" => {
                session
                    .go_forward()
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: "Navigated forward".into(),
                    details: None,
                })
            }

            "reload" => {
                session.reload().await.map_err(|e| ToolError::Internal {
                    message: e.to_string(),
                })?;
                Ok(BrowserResult {
                    content: "Page reloaded".into(),
                    details: None,
                })
            }

            "snapshot" => {
                let text = session.snapshot().await.map_err(|e| ToolError::Internal {
                    message: e.to_string(),
                })?;
                Ok(BrowserResult {
                    content: text,
                    details: None,
                })
            }

            "screenshot" => {
                let b64 = session
                    .screenshot()
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: "Screenshot taken".into(),
                    details: Some(serde_json::json!({
                        "screenshot": b64,
                        "format": "png",
                    })),
                })
            }

            "click" => {
                let selector = require_selector(&action.params)?;
                session
                    .click(selector)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Clicked {selector}"),
                    details: None,
                })
            }

            "fill" => {
                let selector = require_selector(&action.params)?;
                let value = action
                    .params
                    .get("value")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "fill requires 'value' parameter".into(),
                    })?;
                session
                    .fill(selector, value)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Filled {selector}"),
                    details: None,
                })
            }

            "type" => {
                let selector = require_selector(&action.params)?;
                let text = action
                    .params
                    .get("text")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "type requires 'text' parameter".into(),
                    })?;
                let slowly = action
                    .params
                    .get("slowly")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                session
                    .type_text(selector, text, slowly)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Typed into {selector}"),
                    details: None,
                })
            }

            "select" => {
                let selector = require_selector(&action.params)?;
                let value = action
                    .params
                    .get("value")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "select requires 'value' parameter".into(),
                    })?;
                session
                    .select_option(selector, value)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Selected '{value}' in {selector}"),
                    details: None,
                })
            }

            "hover" => {
                let selector = require_selector(&action.params)?;
                session
                    .hover(selector)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Hovered over {selector}"),
                    details: None,
                })
            }

            "pressKey" => {
                let key = action
                    .params
                    .get("key")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "pressKey requires 'key' parameter".into(),
                    })?;
                session
                    .press_key(key)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Pressed key '{key}'"),
                    details: None,
                })
            }

            "wait" => {
                let selector = require_selector(&action.params)?;
                let timeout = action
                    .params
                    .get("timeout")
                    .and_then(Value::as_u64)
                    .unwrap_or(30_000);
                session
                    .wait_for(selector, timeout)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Element {selector} found"),
                    details: None,
                })
            }

            "scroll" => {
                let direction = action
                    .params
                    .get("direction")
                    .and_then(|v| v.as_str())
                    .unwrap_or("down");
                let amount = action
                    .params
                    .get("amount")
                    .and_then(Value::as_i64)
                    .unwrap_or(500);
                session
                    .scroll(direction, amount)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: format!("Scrolled {direction} by {amount}px"),
                    details: None,
                })
            }

            "getText" => {
                let selector = require_selector(&action.params)?;
                let text = session
                    .get_text(selector)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: text,
                    details: None,
                })
            }

            "getAttribute" => {
                let selector = require_selector(&action.params)?;
                let attribute = action
                    .params
                    .get("attribute")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "getAttribute requires 'attribute' parameter".into(),
                    })?;
                let value = session
                    .get_attribute(selector, attribute)
                    .await
                    .map_err(|e| ToolError::Internal {
                        message: e.to_string(),
                    })?;
                Ok(BrowserResult {
                    content: value.unwrap_or_default(),
                    details: None,
                })
            }

            "pdf" => {
                let path = action
                    .params
                    .get("path")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| ToolError::Validation {
                        message: "pdf requires 'path' parameter".into(),
                    })?;
                session.pdf(path).await.map_err(|e| ToolError::Internal {
                    message: e.to_string(),
                })?;
                Ok(BrowserResult {
                    content: format!("PDF saved to {path}"),
                    details: None,
                })
            }

            other => Err(ToolError::Validation {
                message: format!("unknown browser action: {other}"),
            }),
        }
    }

    async fn close_session(&self, session_id: &str) -> Result<(), ToolError> {
        self.service
            .close_session(session_id)
            .await
            .map_err(|e| ToolError::Internal {
                message: e.to_string(),
            })
    }
}

fn require_selector(params: &serde_json::Value) -> Result<&str, ToolError> {
    params
        .get("selector")
        .and_then(|v| v.as_str())
        .ok_or_else(|| ToolError::Validation {
            message: "action requires 'selector' parameter".into(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_action_returns_validation_error() {
        // Test the require_selector helper
        let params = serde_json::json!({});
        let err = require_selector(&params).unwrap_err();
        match err {
            ToolError::Validation { message } => {
                assert!(message.contains("selector"));
            }
            other => panic!("expected Validation, got: {other:?}"),
        }
    }

    #[test]
    fn require_selector_extracts_value() {
        let params = serde_json::json!({"selector": "#btn"});
        let sel = require_selector(&params).unwrap();
        assert_eq!(sel, "#btn");
    }

    #[test]
    fn require_selector_rejects_non_string() {
        let params = serde_json::json!({"selector": 42});
        assert!(require_selector(&params).is_err());
    }
}

/// Integration tests that require Chrome.
#[cfg(test)]
#[cfg(feature = "browser-integration")]
mod integration_tests {
    use super::*;

    fn make_delegate() -> CdpBrowserDelegate {
        let chrome = super::chrome::find_chrome().expect("Chrome required");
        let svc = Arc::new(super::service::BrowserService::new(chrome));
        CdpBrowserDelegate::new(svc)
    }

    #[tokio::test]
    async fn delegate_navigate_action() {
        let d = make_delegate();
        let action = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>Test</h1>"}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Navigated"));
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_screenshot_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>Hi</h1>"}),
        };
        d.execute_action("s1", &nav).await.unwrap();

        let action = BrowserAction {
            action: "screenshot".into(),
            params: serde_json::json!({}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.details.is_some());
        let details = result.details.unwrap();
        assert_eq!(details["format"], "png");
        assert!(details["screenshot"].is_string());
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_snapshot_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>Accessible</h1>"}),
        };
        d.execute_action("s1", &nav).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        let action = BrowserAction {
            action: "snapshot".into(),
            params: serde_json::json!({}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Accessible"));
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_unknown_action_returns_error() {
        let d = make_delegate();
        let action = BrowserAction {
            action: "nonexistent".into(),
            params: serde_json::json!({}),
        };
        let err = d.execute_action("s1", &action).await;
        assert!(err.is_err());
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_navigate_missing_url_returns_error() {
        let d = make_delegate();
        let action = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({}),
        };
        let err = d.execute_action("s1", &action).await;
        assert!(err.is_err());
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_click_missing_selector_returns_error() {
        let d = make_delegate();
        let action = BrowserAction {
            action: "click".into(),
            params: serde_json::json!({}),
        };
        let err = d.execute_action("s1", &action).await;
        assert!(err.is_err());
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_close_action() {
        let d = make_delegate();
        // close_session should work even without prior get_or_create
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_get_text_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": r#"data:text/html,<p id="t">hello world</p>"#}),
        };
        d.execute_action("s1", &nav).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let action = BrowserAction {
            action: "getText".into(),
            params: serde_json::json!({"selector": "#t"}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "hello world");
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_get_attribute_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": r#"data:text/html,<div id="t" data-foo="bar">x</div>"#}),
        };
        d.execute_action("s1", &nav).await.unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let action = BrowserAction {
            action: "getAttribute".into(),
            params: serde_json::json!({"selector": "#t", "attribute": "data-foo"}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert_eq!(result.content, "bar");
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_scroll_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<div style='height:5000px'>tall</div>"}),
        };
        d.execute_action("s1", &nav).await.unwrap();

        let action = BrowserAction {
            action: "scroll".into(),
            params: serde_json::json!({"direction": "down", "amount": 300}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Scrolled"));
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_press_key_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<p>page</p>"}),
        };
        d.execute_action("s1", &nav).await.unwrap();

        let action = BrowserAction {
            action: "pressKey".into(),
            params: serde_json::json!({"key": "Enter"}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("Enter"));
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_reload_action() {
        let d = make_delegate();
        let nav = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<p>page</p>"}),
        };
        d.execute_action("s1", &nav).await.unwrap();

        let action = BrowserAction {
            action: "reload".into(),
            params: serde_json::json!({}),
        };
        let result = d.execute_action("s1", &action).await.unwrap();
        assert!(result.content.contains("reloaded"));
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_auto_starts_screencast() {
        let chrome = super::chrome::find_chrome().expect("Chrome required");
        let svc = Arc::new(super::service::BrowserService::new(chrome));
        let d = CdpBrowserDelegate::new(Arc::clone(&svc));

        let action = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>Auto</h1>"}),
        };
        d.execute_action("s1", &action).await.unwrap();

        let status = svc.get_status("s1");
        assert!(
            status.is_streaming,
            "delegate should auto-start screencast on first action"
        );
        d.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn delegate_does_not_restart_screencast() {
        let chrome = super::chrome::find_chrome().expect("Chrome required");
        let svc = Arc::new(super::service::BrowserService::new(chrome));
        let d = CdpBrowserDelegate::new(Arc::clone(&svc));

        // First action: triggers auto-start
        let action = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>First</h1>"}),
        };
        d.execute_action("s1", &action).await.unwrap();
        assert!(svc.get_status("s1").is_streaming);

        // Second action: should NOT restart (already streaming)
        let action2 = BrowserAction {
            action: "navigate".into(),
            params: serde_json::json!({"url": "data:text/html,<h1>Second</h1>"}),
        };
        d.execute_action("s1", &action2).await.unwrap();
        assert!(svc.get_status("s1").is_streaming);

        d.close_session("s1").await.unwrap();
    }
}
