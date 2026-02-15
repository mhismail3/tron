//! `send_message` tool — sends inter-session messages.
//!
//! Sends a message to another agent session via the [`MessageBus`].
//! Supports optional reply waiting with configurable timeout.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{MessageBus, OutgoingMessage, ToolContext, TronTool};
use crate::utils::validation::{get_optional_bool, get_optional_u64, validate_required_string};

const DEFAULT_REPLY_TIMEOUT_MS: u64 = 30_000;

/// The `send_message` tool sends messages to other agent sessions.
pub struct SendMessageTool {
    bus: Arc<dyn MessageBus>,
}

impl SendMessageTool {
    /// Create a new `send_message` tool with the given message bus.
    pub fn new(bus: Arc<dyn MessageBus>) -> Self {
        Self { bus }
    }
}

#[async_trait]
impl TronTool for SendMessageTool {
    fn name(&self) -> &str {
        "send_message"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "send_message".into(),
            description: "Send a message to another agent session.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("targetSessionId".into(), json!({"type": "string", "description": "Session ID to send the message to"}));
                    let _ = m.insert("messageType".into(), json!({"type": "string", "description": "Type of message for routing"}));
                    let _ = m.insert("payload".into(), json!({"type": "object", "description": "Message content/data"}));
                    let _ = m.insert("waitForReply".into(), json!({"type": "boolean", "description": "Whether to wait for a reply"}));
                    let _ = m.insert("timeout".into(), json!({"type": "number", "description": "Timeout in ms when waiting for reply (default: 30000)"}));
                    m
                }),
                required: Some(vec![
                    "targetSessionId".into(),
                    "messageType".into(),
                    "payload".into(),
                ]),
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
        let target = match validate_required_string(&params, "targetSessionId", "target session ID") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let message_type = match validate_required_string(&params, "messageType", "message type") {
            Ok(t) => t,
            Err(e) => return Ok(e),
        };

        let payload = match params.get("payload") {
            Some(p) => p.clone(),
            None => return Ok(error_result("Missing required parameter: payload")),
        };

        let wait_for_reply = get_optional_bool(&params, "waitForReply").unwrap_or(false);
        let timeout_ms = get_optional_u64(&params, "timeout").unwrap_or(DEFAULT_REPLY_TIMEOUT_MS);

        let msg = OutgoingMessage {
            target_session_id: target,
            message_type,
            payload,
            wait_for_reply,
            timeout_ms,
        };

        match self.bus.send_message(&msg).await {
            Ok(result) => {
                let content = if let Some(reply) = &result.reply {
                    format!(
                        "Message sent and reply received (id: {}, reply: {})",
                        result.message_id,
                        serde_json::to_string(reply).unwrap_or_default()
                    )
                } else {
                    format!("Message sent successfully (id: {})", result.message_id)
                };

                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(content),
                    ]),
                    details: Some(json!({
                        "messageId": result.message_id,
                        "reply": result.reply,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(error_result(format!("Failed to send message: {e}"))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{MessageFilter, MessageSendResult, ReceivedMessage};

    struct MockBus {
        should_fail: bool,
        reply: Option<Value>,
    }

    impl MockBus {
        fn success() -> Self {
            Self {
                should_fail: false,
                reply: None,
            }
        }

        fn with_reply() -> Self {
            Self {
                should_fail: false,
                reply: Some(json!({"answer": 42})),
            }
        }

        fn failing() -> Self {
            Self {
                should_fail: true,
                reply: None,
            }
        }
    }

    #[async_trait]
    impl MessageBus for MockBus {
        async fn send_message(&self, _msg: &OutgoingMessage) -> Result<MessageSendResult, ToolError> {
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "bus error".into(),
                });
            }
            Ok(MessageSendResult {
                message_id: "msg-1".into(),
                reply: self.reply.clone(),
            })
        }

        async fn receive_messages(
            &self,
            _session_id: &str,
            _filter: &MessageFilter,
        ) -> Result<Vec<ReceivedMessage>, ToolError> {
            Ok(vec![])
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
    async fn valid_message_sent() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(
                json!({
                    "targetSessionId": "other-sess",
                    "messageType": "task",
                    "payload": {"data": "hello"}
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Message sent successfully"));
        assert!(text.contains("msg-1"));
    }

    #[tokio::test]
    async fn wait_for_reply() {
        let tool = SendMessageTool::new(Arc::new(MockBus::with_reply()));
        let r = tool
            .execute(
                json!({
                    "targetSessionId": "other-sess",
                    "messageType": "query",
                    "payload": {"q": "?"},
                    "waitForReply": true
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("reply received"));
    }

    #[tokio::test]
    async fn no_wait_returns_immediately() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(
                json!({
                    "targetSessionId": "t",
                    "messageType": "m",
                    "payload": {},
                    "waitForReply": false
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["messageId"], "msg-1");
    }

    #[tokio::test]
    async fn missing_target_error() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(json!({"messageType": "t", "payload": {}}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_message_type_error() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(json!({"targetSessionId": "t", "payload": {}}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_payload_error() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(json!({"targetSessionId": "t", "messageType": "m"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn bus_error() {
        let tool = SendMessageTool::new(Arc::new(MockBus::failing()));
        let r = tool
            .execute(
                json!({
                    "targetSessionId": "t",
                    "messageType": "m",
                    "payload": {}
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Failed to send"));
    }

    #[tokio::test]
    async fn default_timeout() {
        let tool = SendMessageTool::new(Arc::new(MockBus::success()));
        let r = tool
            .execute(
                json!({
                    "targetSessionId": "t",
                    "messageType": "m",
                    "payload": {}
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }
}
