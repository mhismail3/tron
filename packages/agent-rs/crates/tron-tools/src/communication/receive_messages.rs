//! `receive_messages` tool — receives inter-session messages.
//!
//! Checks for messages sent to this session from other agents. Supports
//! filtering by type and sender, with optional mark-as-read behavior.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult};

use crate::errors::ToolError;
use crate::traits::{MessageBus, MessageFilter, ToolContext, TronTool};
use crate::utils::validation::{get_optional_bool, get_optional_string, get_optional_u64};

const DEFAULT_LIMIT: u32 = 20;

/// The `receive_messages` tool checks for messages from other agents.
pub struct ReceiveMessagesTool {
    bus: Arc<dyn MessageBus>,
}

impl ReceiveMessagesTool {
    /// Create a new `receive_messages` tool with the given message bus.
    pub fn new(bus: Arc<dyn MessageBus>) -> Self {
        Self { bus }
    }
}

#[async_trait]
impl TronTool for ReceiveMessagesTool {
    fn name(&self) -> &str {
        "receive_messages"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "receive_messages".into(),
            description: "Check for messages sent to this session from other agents. Can filter by type or sender.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("type".into(), json!({"type": "string", "description": "Filter by message type"}));
                    let _ = m.insert("fromSessionId".into(), json!({"type": "string", "description": "Filter by sender session ID"}));
                    let _ = m.insert("limit".into(), json!({"type": "number", "description": "Maximum messages to return (default: 20)"}));
                    let _ = m.insert("markAsRead".into(), json!({"type": "boolean", "description": "Whether to mark returned messages as read (default: true)"}));
                    m
                }),
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let message_type = get_optional_string(&params, "type");
        let from_session_id = get_optional_string(&params, "fromSessionId");
        let mark_as_read = get_optional_bool(&params, "markAsRead").unwrap_or(true);
        #[allow(clippy::cast_possible_truncation)]
        let limit = get_optional_u64(&params, "limit").map_or(DEFAULT_LIMIT, |v| v as u32);

        let filter = MessageFilter {
            message_type,
            from_session_id,
            mark_as_read,
            limit: Some(limit),
        };

        match self.bus.receive_messages(&ctx.session_id, &filter).await {
            Ok(messages) => {
                if messages.is_empty() {
                    return Ok(TronToolResult {
                        content: ToolResultBody::Blocks(vec![
                            tron_core::content::ToolResultContent::text("No messages found."),
                        ]),
                        details: Some(json!({
                            "messages": [],
                            "count": 0,
                        })),
                        is_error: None,
                        stop_turn: None,
                    });
                }

                let summary = messages
                    .iter()
                    .map(|m| {
                        let payload_str = serde_json::to_string(&m.payload).unwrap_or_default();
                        let truncated =
                            tron_core::text::truncate_with_suffix(&payload_str, 103, "...");
                        format!(
                            "- [{}] from {}: {}",
                            m.message_type, m.from_session_id, truncated
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n");

                let content = format!("Found {} messages:\n{summary}", messages.len());

                let msg_details: Vec<Value> = messages
                    .iter()
                    .map(|m| {
                        json!({
                            "messageId": m.message_id,
                            "fromSessionId": m.from_session_id,
                            "messageType": m.message_type,
                            "payload": m.payload,
                            "timestamp": m.timestamp,
                        })
                    })
                    .collect();

                Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(content),
                    ]),
                    details: Some(json!({
                        "messages": msg_details,
                        "count": messages.len(),
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
            Err(e) => Ok(tron_core::tools::error_result(format!(
                "Failed to receive messages: {e}"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{MessageSendResult, OutgoingMessage, ReceivedMessage};

    struct MockBus {
        messages: Vec<ReceivedMessage>,
        should_fail: bool,
    }

    impl MockBus {
        fn empty() -> Self {
            Self {
                messages: vec![],
                should_fail: false,
            }
        }

        fn with_messages(messages: Vec<ReceivedMessage>) -> Self {
            Self {
                messages,
                should_fail: false,
            }
        }

        fn failing() -> Self {
            Self {
                messages: vec![],
                should_fail: true,
            }
        }
    }

    #[async_trait]
    impl MessageBus for MockBus {
        async fn send_message(
            &self,
            _msg: &OutgoingMessage,
        ) -> Result<MessageSendResult, ToolError> {
            Ok(MessageSendResult {
                message_id: "msg-1".into(),
                reply: None,
            })
        }

        async fn receive_messages(
            &self,
            _session_id: &str,
            _filter: &MessageFilter,
        ) -> Result<Vec<ReceivedMessage>, ToolError> {
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "bus error".into(),
                });
            }
            Ok(self.messages.clone())
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

    fn sample_message() -> ReceivedMessage {
        ReceivedMessage {
            message_id: "msg-1".into(),
            from_session_id: "other-sess".into(),
            message_type: "task".into(),
            payload: json!({"data": "hello"}),
            timestamp: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[tokio::test]
    async fn no_messages() {
        let tool = ReceiveMessagesTool::new(Arc::new(MockBus::empty()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("No messages"));
        let d = r.details.unwrap();
        assert_eq!(d["count"], 0);
    }

    #[tokio::test]
    async fn with_messages() {
        let tool =
            ReceiveMessagesTool::new(Arc::new(MockBus::with_messages(vec![sample_message()])));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Found 1 messages"));
        assert!(text.contains("[task]"));
        assert!(text.contains("other-sess"));
    }

    #[tokio::test]
    async fn type_filter() {
        let tool =
            ReceiveMessagesTool::new(Arc::new(MockBus::with_messages(vec![sample_message()])));
        let r = tool
            .execute(json!({"type": "task"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn from_session_filter() {
        let tool =
            ReceiveMessagesTool::new(Arc::new(MockBus::with_messages(vec![sample_message()])));
        let r = tool
            .execute(json!({"fromSessionId": "other-sess"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn mark_as_read_default_true() {
        let tool = ReceiveMessagesTool::new(Arc::new(MockBus::empty()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn mark_as_read_false() {
        let tool = ReceiveMessagesTool::new(Arc::new(MockBus::empty()));
        let r = tool
            .execute(json!({"markAsRead": false}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn limit_respected() {
        let tool =
            ReceiveMessagesTool::new(Arc::new(MockBus::with_messages(vec![sample_message()])));
        let r = tool
            .execute(json!({"limit": 5}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn bus_error() {
        let tool = ReceiveMessagesTool::new(Arc::new(MockBus::failing()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Failed to receive"));
    }

    #[tokio::test]
    async fn message_details_included() {
        let tool =
            ReceiveMessagesTool::new(Arc::new(MockBus::with_messages(vec![sample_message()])));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        let msgs = d["messages"].as_array().unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0]["messageId"], "msg-1");
        assert_eq!(msgs[0]["fromSessionId"], "other-sess");
    }
}
