//! Persisted session-event discriminators.
//!
//! This list contains only event families with a production writer or a
//! production reconstruction path. Live-only progress and delta events belong
//! to the transport protocol, not the durable session log.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
/// Discriminator for records accepted by the durable session event log.
pub enum EventType {
    /// Session creation record.
    #[serde(rename = "session.start")]
    SessionStart,
    /// Session terminal record.
    #[serde(rename = "session.end")]
    SessionEnd,
    /// Session fork record.
    #[serde(rename = "session.fork")]
    SessionFork,
    /// Durable model-selection change for the session.
    #[serde(rename = "session.model_changed")]
    SessionModelChanged,
    /// Durable reasoning-level selection for the session.
    #[serde(rename = "session.reasoning_changed")]
    SessionReasoningChanged,
    /// User message record.
    #[serde(rename = "message.user")]
    MessageUser,
    /// Assistant message record.
    #[serde(rename = "message.assistant")]
    MessageAssistant,
    /// Redacted provider-request audit record.
    #[serde(rename = "model.provider_request")]
    ModelProviderRequest,
    /// Soft-deletion record for a prior message.
    #[serde(rename = "message.deleted")]
    MessageDeleted,
    /// Tool invocation start record.
    #[serde(rename = "tool.invocation.started")]
    ToolInvocationStarted,
    /// Tool invocation terminal record.
    #[serde(rename = "tool.invocation.completed")]
    ToolInvocationCompleted,
    /// Agent turn start record.
    #[serde(rename = "stream.turn_start")]
    StreamTurnStart,
    /// Agent turn terminal record.
    #[serde(rename = "stream.turn_end")]
    StreamTurnEnd,
    /// Committed context-compaction boundary.
    #[serde(rename = "compact.boundary")]
    CompactBoundary,
    /// Failed turn terminal record.
    #[serde(rename = "turn.failed")]
    TurnFailed,
}

impl EventType {
    /// Return the canonical storage and protocol discriminator.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SessionStart => "session.start",
            Self::SessionEnd => "session.end",
            Self::SessionFork => "session.fork",
            Self::SessionModelChanged => "session.model_changed",
            Self::SessionReasoningChanged => "session.reasoning_changed",
            Self::MessageUser => "message.user",
            Self::MessageAssistant => "message.assistant",
            Self::ModelProviderRequest => "model.provider_request",
            Self::MessageDeleted => "message.deleted",
            Self::ToolInvocationStarted => "tool.invocation.started",
            Self::ToolInvocationCompleted => "tool.invocation.completed",
            Self::StreamTurnStart => "stream.turn_start",
            Self::StreamTurnEnd => "stream.turn_end",
            Self::CompactBoundary => "compact.boundary",
            Self::TurnFailed => "turn.failed",
        }
    }
}

impl std::fmt::Display for EventType {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl std::str::FromStr for EventType {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "session.start" => Ok(Self::SessionStart),
            "session.end" => Ok(Self::SessionEnd),
            "session.fork" => Ok(Self::SessionFork),
            "session.model_changed" => Ok(Self::SessionModelChanged),
            "session.reasoning_changed" => Ok(Self::SessionReasoningChanged),
            "message.user" => Ok(Self::MessageUser),
            "message.assistant" => Ok(Self::MessageAssistant),
            "model.provider_request" => Ok(Self::ModelProviderRequest),
            "message.deleted" => Ok(Self::MessageDeleted),
            "tool.invocation.started" => Ok(Self::ToolInvocationStarted),
            "tool.invocation.completed" => Ok(Self::ToolInvocationCompleted),
            "stream.turn_start" => Ok(Self::StreamTurnStart),
            "stream.turn_end" => Ok(Self::StreamTurnEnd),
            "compact.boundary" => Ok(Self::CompactBoundary),
            "turn.failed" => Ok(Self::TurnFailed),
            _ => Err(format!("unknown event type: {value}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [EventType; 15] = [
        EventType::SessionStart,
        EventType::SessionEnd,
        EventType::SessionFork,
        EventType::SessionModelChanged,
        EventType::SessionReasoningChanged,
        EventType::MessageUser,
        EventType::MessageAssistant,
        EventType::ModelProviderRequest,
        EventType::MessageDeleted,
        EventType::ToolInvocationStarted,
        EventType::ToolInvocationCompleted,
        EventType::StreamTurnStart,
        EventType::StreamTurnEnd,
        EventType::CompactBoundary,
        EventType::TurnFailed,
    ];

    #[test]
    fn wire_roundtrip_is_complete() {
        for event_type in ALL {
            let wire = event_type.as_str();
            assert_eq!(wire.parse::<EventType>().unwrap(), event_type);
            assert_eq!(serde_json::to_value(event_type).unwrap(), wire);
            assert_eq!(
                serde_json::from_value::<EventType>(serde_json::json!(wire)).unwrap(),
                event_type
            );
        }
    }
}
