//! Event type definitions for the primitive session loop.
//!
//! All definitions are produced by [`define_events!`] from a single
//! source-of-truth table. Add or remove events by modifying the macro
//! invocation below.

use serde::{Deserialize, Serialize};

use super::base::SessionEvent;
use super::payloads;

define_events! {
    events {
        /// New session started.
        SessionStart => "session.start" => payloads::session::SessionStartPayload,
        /// Session ended.
        SessionEnd => "session.end" => payloads::session::SessionEndPayload,
        /// Session forked from another.
        SessionFork => "session.fork" => payloads::session::SessionForkPayload,
        /// User message.
        MessageUser => "message.user" => payloads::message::UserMessagePayload,
        /// Assistant (model) message.
        MessageAssistant => "message.assistant" => payloads::message::AssistantMessagePayload,
        /// System-injected message.
        MessageSystem => "message.system" => payloads::message::SystemMessagePayload,
        /// Provider request audit persisted before model streaming starts.
        ModelProviderRequest => "model.provider_request" => payloads::model::ModelProviderRequestPayload,
        /// Message deleted (soft delete).
        MessageDeleted => "message.deleted" => payloads::message_ops::MessageDeletedPayload,
        /// Capability invocation started.
        CapabilityInvocationStarted => "capability.invocation.started" => payloads::capability_invocation::CapabilityInvocationStartedPayload,
        /// Capability invocation completed.
        CapabilityInvocationCompleted => "capability.invocation.completed" => payloads::capability_invocation::CapabilityInvocationCompletedPayload,
        /// Capability invocation progress update.
        CapabilityInvocationProgress => "capability.invocation.progress" => payloads::capability_invocation::CapabilityInvocationProgressPayload,
        /// Text delta during streaming.
        StreamTextDelta => "stream.text_delta" => payloads::streaming::StreamTextDeltaPayload,
        /// Thinking delta during streaming.
        StreamThinkingDelta => "stream.thinking_delta" => payloads::streaming::StreamThinkingDeltaPayload,
        /// Turn started streaming.
        StreamTurnStart => "stream.turn_start" => payloads::streaming::StreamTurnStartPayload,
        /// Turn finished streaming.
        StreamTurnEnd => "stream.turn_end" => payloads::streaming::StreamTurnEndPayload,
        /// Compaction boundary marker.
        CompactBoundary => "compact.boundary" => payloads::compact::CompactBoundaryPayload,
        /// Phase 1 of the H13 compaction two-phase commit: summary produced,
        /// boundary not yet committed. Durably preserves the summarizer's
        /// output before the context is mutated and the boundary persist is
        /// attempted. Reconstruction ignores a staging event without a
        /// matching successor `CompactBoundary`.
        CompactSummaryStaging => "compact.summary_staging" => payloads::compact::CompactSummaryStagingPayload,
        /// Context cleared.
        ContextCleared => "context.cleared" => payloads::context::ContextClearedPayload,
        /// Session metadata updated.
        MetadataUpdate => "metadata.update" => payloads::metadata::MetadataUpdatePayload,
        /// Session tag added/removed.
        MetadataTag => "metadata.tag" => payloads::metadata::MetadataTagPayload,
        /// Agent-level error.
        ErrorAgent => "error.agent" => payloads::error::ErrorAgentPayload,
        /// Capability invocation error.
        ErrorCapability => "error.capability" => payloads::error::ErrorCapabilityPayload,
        /// Provider (LLM) error.
        ErrorProvider => "error.provider" => payloads::error::ErrorProviderPayload,
        /// Turn failed.
        TurnFailed => "turn.failed" => payloads::turn::TurnFailedPayload
    }
    raw_events {
    }
    domain_groups {
        /// Whether this is a session lifecycle event (`session.*`).
        is_session_type => [SessionStart, SessionEnd, SessionFork],
        /// Whether this is a message event (`message.user|assistant|system`).
        is_message_type => [MessageUser, MessageAssistant, MessageSystem],
        /// Whether this is a streaming event (`stream.*`).
        is_streaming_type => [StreamTextDelta, StreamThinkingDelta, StreamTurnStart, StreamTurnEnd],
        /// Whether this is an error event (`error.*`).
        is_error_type => [ErrorAgent, ErrorCapability, ErrorProvider],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXPECTED: [(EventType, &str); 24] = [
        (EventType::SessionStart, "session.start"),
        (EventType::SessionEnd, "session.end"),
        (EventType::SessionFork, "session.fork"),
        (EventType::MessageUser, "message.user"),
        (EventType::MessageAssistant, "message.assistant"),
        (EventType::MessageSystem, "message.system"),
        (EventType::ModelProviderRequest, "model.provider_request"),
        (EventType::MessageDeleted, "message.deleted"),
        (
            EventType::CapabilityInvocationStarted,
            "capability.invocation.started",
        ),
        (
            EventType::CapabilityInvocationCompleted,
            "capability.invocation.completed",
        ),
        (
            EventType::CapabilityInvocationProgress,
            "capability.invocation.progress",
        ),
        (EventType::StreamTextDelta, "stream.text_delta"),
        (EventType::StreamThinkingDelta, "stream.thinking_delta"),
        (EventType::StreamTurnStart, "stream.turn_start"),
        (EventType::StreamTurnEnd, "stream.turn_end"),
        (EventType::CompactBoundary, "compact.boundary"),
        (EventType::CompactSummaryStaging, "compact.summary_staging"),
        (EventType::ContextCleared, "context.cleared"),
        (EventType::MetadataUpdate, "metadata.update"),
        (EventType::MetadataTag, "metadata.tag"),
        (EventType::ErrorAgent, "error.agent"),
        (EventType::ErrorCapability, "error.capability"),
        (EventType::ErrorProvider, "error.provider"),
        (EventType::TurnFailed, "turn.failed"),
    ];

    #[test]
    fn all_event_types_constant_has_correct_count() {
        assert_eq!(ALL_EVENT_TYPES.len(), 24);
    }

    #[test]
    fn all_event_types_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for et in &ALL_EVENT_TYPES {
            assert!(seen.insert(et), "duplicate event type: {et}");
        }
    }

    #[test]
    fn as_str_matches_expected() {
        for (variant, expected) in &EXPECTED {
            assert_eq!(
                variant.as_str(),
                *expected,
                "as_str mismatch for {variant:?}"
            );
        }
    }

    #[test]
    fn as_str_matches_serde() {
        for et in &ALL_EVENT_TYPES {
            let json = serde_json::to_value(et).unwrap();
            assert_eq!(
                json.as_str().unwrap(),
                et.as_str(),
                "serde mismatch for {et:?}"
            );
        }
    }

    #[test]
    fn display_matches_as_str() {
        for et in &ALL_EVENT_TYPES {
            assert_eq!(format!("{et}"), et.as_str());
        }
    }

    #[test]
    fn serde_roundtrip_all_variants() {
        for (variant, expected_str) in &EXPECTED {
            let json = serde_json::to_value(variant).unwrap();
            assert_eq!(
                json,
                serde_json::Value::String(expected_str.to_string()),
                "serialize mismatch for {variant:?}"
            );
            let back: EventType = serde_json::from_value(json).unwrap();
            assert_eq!(*variant, back, "roundtrip mismatch for {variant:?}");
        }
    }

    #[test]
    fn from_str_roundtrip() {
        for (variant, expected_str) in &EXPECTED {
            let parsed: EventType = expected_str.parse().unwrap();
            assert_eq!(*variant, parsed);
        }
    }

    #[test]
    fn from_str_rejects_invalid() {
        let err = "not.a.type".parse::<EventType>();
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("unknown event type"));
    }

    #[test]
    fn from_str_rejects_empty() {
        assert!("".parse::<EventType>().is_err());
    }

    #[test]
    fn from_str_rejects_retired_spell_types() {
        // Primitive branch invariant: old spell event-type strings must fail
        // to parse because the fresh schema has no historical event surface.
        assert!("spell.cast".parse::<EventType>().is_err());
        assert!("spell.consumed".parse::<EventType>().is_err());
    }

    #[test]
    fn from_str_rejects_retired_compact_summary_type() {
        assert!("compact.summary".parse::<EventType>().is_err());
    }

    #[test]
    fn from_str_rejects_retired_message_queue_types() {
        assert!(
            concat!("message", ".", "queued")
                .parse::<EventType>()
                .is_err()
        );
        assert!(
            concat!("message", ".", "dequeued")
                .parse::<EventType>()
                .is_err()
        );
    }

    #[test]
    fn serde_roundtrip_from_string() {
        for et in &ALL_EVENT_TYPES {
            let s = et.as_str();
            let json_str = format!("\"{s}\"");
            let parsed: EventType = serde_json::from_str(&json_str).unwrap();
            assert_eq!(*et, parsed);
        }
    }

    // -- Domain helpers --

    #[test]
    fn is_message_type() {
        assert!(EventType::MessageUser.is_message_type());
        assert!(EventType::MessageAssistant.is_message_type());
        assert!(EventType::MessageSystem.is_message_type());
        assert!(!EventType::MessageDeleted.is_message_type());
        assert!(!EventType::CapabilityInvocationStarted.is_message_type());
    }

    #[test]
    fn is_streaming_type() {
        assert!(EventType::StreamTextDelta.is_streaming_type());
        assert!(EventType::StreamThinkingDelta.is_streaming_type());
        assert!(EventType::StreamTurnStart.is_streaming_type());
        assert!(EventType::StreamTurnEnd.is_streaming_type());
        assert!(!EventType::MessageUser.is_streaming_type());
    }

    #[test]
    fn is_error_type() {
        assert!(EventType::ErrorAgent.is_error_type());
        assert!(EventType::ErrorCapability.is_error_type());
        assert!(EventType::ErrorProvider.is_error_type());
        assert!(!EventType::CapabilityInvocationCompleted.is_error_type());
    }

    #[test]
    fn is_session_type() {
        assert!(EventType::SessionStart.is_session_type());
        assert!(EventType::SessionEnd.is_session_type());
        assert!(EventType::SessionFork.is_session_type());
        assert!(!EventType::MessageUser.is_session_type());
    }

    #[test]
    fn domain_extraction() {
        assert_eq!(EventType::SessionStart.domain(), "session");
        assert_eq!(EventType::MessageUser.domain(), "message");
        assert_eq!(
            EventType::CapabilityInvocationStarted.domain(),
            "capability"
        );
        assert_eq!(EventType::StreamTextDelta.domain(), "stream");
        assert_eq!(EventType::CompactBoundary.domain(), "compact");
        assert_eq!(EventType::ErrorAgent.domain(), "error");
        assert_eq!(EventType::TurnFailed.domain(), "turn");
    }

    #[test]
    fn into_typed_payload_matches_typed_payload() {
        let event = SessionEvent {
            id: "evt-1".into(),
            parent_id: None,
            session_id: "s".into(),
            workspace_id: "w".into(),
            timestamp: "t".into(),
            event_type: EventType::SessionStart,
            sequence: 1,
            checksum: None,
            payload: serde_json::json!({
                "workingDirectory": "/test",
                "model": "claude-opus-4-6",
                "provider": "anthropic"
            }),
        };
        let cloned = event.typed_payload().unwrap();
        let owned = event.into_typed_payload().unwrap();
        assert_eq!(cloned, owned);
    }
}
