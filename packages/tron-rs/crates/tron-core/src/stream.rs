use serde::{Deserialize, Serialize};

use crate::errors::GatewayError;
use crate::ids::ToolCallId;
use crate::messages::{AssistantMessage, StopReason, ToolCallBlock};

/// Events emitted during LLM streaming. Strict ordering contract:
///
/// Start → (TextStart → TextDelta* → TextEnd | ThinkingStart → ThinkingDelta* → ThinkingEnd |
///          ToolCallStart → ToolCallDelta* → ToolCallEnd)* → Done
///
/// Error or Retry can appear at any point.
#[derive(Clone, Debug)]
pub enum StreamEvent {
    Start,

    TextStart,
    TextDelta { delta: String },
    TextEnd { text: String, signature: Option<String> },

    ThinkingStart,
    ThinkingDelta { delta: String },
    ThinkingEnd { thinking: String, signature: Option<String> },

    ToolCallStart { tool_call_id: ToolCallId, name: String },
    ToolCallDelta { tool_call_id: ToolCallId, arguments_delta: String },
    ToolCallEnd { tool_call: ToolCallBlock },

    Done { message: AssistantMessage, stop_reason: StopReason },
    Error { error: GatewayError },
    Retry { attempt: u32, max_retries: u32, delay_ms: u64, error: GatewayErrorInfo },
}

/// Lightweight error info for retry events (no full GatewayError ownership issues).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GatewayErrorInfo {
    pub kind: String,
    pub message: String,
}

impl From<&GatewayError> for GatewayErrorInfo {
    fn from(e: &GatewayError) -> Self {
        Self {
            kind: e.error_kind().to_string(),
            message: e.to_string(),
        }
    }
}

/// Which content block type is currently being streamed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ActiveBlock {
    None,
    Text,
    Thinking,
    ToolCall(ToolCallId),
}

impl StreamEvent {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Done { .. } | Self::Error { .. })
    }

    pub fn is_content_delta(&self) -> bool {
        matches!(
            self,
            Self::TextDelta { .. } | Self::ThinkingDelta { .. } | Self::ToolCallDelta { .. }
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_classification() {
        let done = StreamEvent::Done {
            message: AssistantMessage::text("hi"),
            stop_reason: StopReason::EndTurn,
        };
        assert!(done.is_terminal());

        let delta = StreamEvent::TextDelta { delta: "x".into() };
        assert!(!delta.is_terminal());
        assert!(delta.is_content_delta());
    }

    #[test]
    fn error_info_from_gateway_error() {
        let err = GatewayError::RateLimited { retry_after: None };
        let info = GatewayErrorInfo::from(&err);
        assert_eq!(info.kind, "rate_limited");
        assert!(info.message.contains("rate limited"));
    }
}
