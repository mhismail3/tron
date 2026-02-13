//! WebSocket event broadcasting types.
//!
//! [`BroadcastEventType`] enumerates all event types that can be pushed to
//! connected clients over WebSocket. [`EventEnvelope`] wraps an event with
//! metadata for transport.
//!
//! These types match the TypeScript wire format exactly — iOS and chat-web
//! depend on the string values.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Event types broadcast to WebSocket clients.
///
/// Each variant serializes to a dot-separated string matching the TypeScript
/// `BroadcastEventType` constant object.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BroadcastEventType {
    // ── Session ──────────────────────────────────────────────────────
    /// A new session was created.
    #[serde(rename = "session.created")]
    SessionCreated,
    /// A session ended.
    #[serde(rename = "session.ended")]
    SessionEnded,
    /// A session was forked from another.
    #[serde(rename = "session.forked")]
    SessionForked,
    /// A session was rewound to an earlier state.
    #[serde(rename = "session.rewound")]
    SessionRewound,

    // ── Agent ────────────────────────────────────────────────────────
    /// A complete agent turn (request → response → tool results).
    #[serde(rename = "agent.turn")]
    AgentTurn,
    /// A message was deleted from the session.
    #[serde(rename = "agent.message_deleted")]
    AgentMessageDeleted,
    /// Context was cleared for the session.
    #[serde(rename = "agent.context_cleared")]
    AgentContextCleared,
    /// Context compaction completed.
    #[serde(rename = "agent.compaction")]
    AgentCompaction,
    /// Memory ledger update in progress.
    #[serde(rename = "agent.memory_updating")]
    AgentMemoryUpdating,
    /// Memory ledger update completed.
    #[serde(rename = "agent.memory_updated")]
    AgentMemoryUpdated,
    /// A skill was removed from the session.
    #[serde(rename = "agent.skill_removed")]
    AgentSkillRemoved,
    /// The todo list was updated.
    #[serde(rename = "agent.todos_updated")]
    AgentTodosUpdated,

    // ── Task ─────────────────────────────────────────────────────────
    /// A task was created.
    #[serde(rename = "task.created")]
    TaskCreated,
    /// A task was updated.
    #[serde(rename = "task.updated")]
    TaskUpdated,
    /// A task was deleted.
    #[serde(rename = "task.deleted")]
    TaskDeleted,

    // ── Project ──────────────────────────────────────────────────────
    /// A project was created.
    #[serde(rename = "project.created")]
    ProjectCreated,
    /// A project was updated.
    #[serde(rename = "project.updated")]
    ProjectUpdated,
    /// A project was deleted.
    #[serde(rename = "project.deleted")]
    ProjectDeleted,

    // ── Area ─────────────────────────────────────────────────────────
    /// An area was created.
    #[serde(rename = "area.created")]
    AreaCreated,
    /// An area was updated.
    #[serde(rename = "area.updated")]
    AreaUpdated,
    /// An area was deleted.
    #[serde(rename = "area.deleted")]
    AreaDeleted,

    // ── Browser ──────────────────────────────────────────────────────
    /// A browser frame (screenshot) is available.
    #[serde(rename = "browser.frame")]
    BrowserFrame,
    /// The browser was closed.
    #[serde(rename = "browser.closed")]
    BrowserClosed,

    // ── Event store ──────────────────────────────────────────────────
    /// A new event was persisted to the store.
    #[serde(rename = "event.new")]
    EventNew,
}

/// All broadcast event type variants, for exhaustive testing.
pub const ALL_BROADCAST_EVENT_TYPES: &[BroadcastEventType] = &[
    BroadcastEventType::SessionCreated,
    BroadcastEventType::SessionEnded,
    BroadcastEventType::SessionForked,
    BroadcastEventType::SessionRewound,
    BroadcastEventType::AgentTurn,
    BroadcastEventType::AgentMessageDeleted,
    BroadcastEventType::AgentContextCleared,
    BroadcastEventType::AgentCompaction,
    BroadcastEventType::AgentMemoryUpdating,
    BroadcastEventType::AgentMemoryUpdated,
    BroadcastEventType::AgentSkillRemoved,
    BroadcastEventType::AgentTodosUpdated,
    BroadcastEventType::TaskCreated,
    BroadcastEventType::TaskUpdated,
    BroadcastEventType::TaskDeleted,
    BroadcastEventType::ProjectCreated,
    BroadcastEventType::ProjectUpdated,
    BroadcastEventType::ProjectDeleted,
    BroadcastEventType::AreaCreated,
    BroadcastEventType::AreaUpdated,
    BroadcastEventType::AreaDeleted,
    BroadcastEventType::BrowserFrame,
    BroadcastEventType::BrowserClosed,
    BroadcastEventType::EventNew,
];

/// Envelope wrapping an event for WebSocket broadcast.
///
/// Matches the TypeScript `EventEnvelope` interface exactly:
/// ```json
/// { "type": "event.new", "sessionId": "sess_...", "timestamp": "2025-...", "data": {...} }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventEnvelope {
    /// Broadcast event type.
    #[serde(rename = "type")]
    pub event_type: String,
    /// Associated session ID (absent for system-wide events).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// ISO 8601 timestamp.
    pub timestamp: String,
    /// Event payload — shape varies by event type.
    pub data: Value,
}

/// Create an [`EventEnvelope`] with automatic timestamp and session ID extraction.
///
/// If `session_id` is `None`, the function attempts to extract it from
/// `data["sessionId"]`. If `data` contains a `"timestamp"` field, it is
/// preserved; otherwise the current UTC time is used.
pub fn create_event_envelope(
    event_type: &str,
    data: Value,
    session_id: Option<&str>,
) -> EventEnvelope {
    let resolved_session_id = session_id
        .map(String::from)
        .or_else(|| data.get("sessionId").and_then(|v| v.as_str()).map(String::from));

    let timestamp = data
        .get("timestamp")
        .and_then(|v| v.as_str())
        .map_or_else(|| chrono::Utc::now().to_rfc3339(), String::from);

    EventEnvelope {
        event_type: event_type.to_string(),
        session_id: resolved_session_id,
        timestamp,
        data,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── BroadcastEventType serde ─────────────────────────────────────

    #[test]
    fn all_broadcast_types_count() {
        assert_eq!(ALL_BROADCAST_EVENT_TYPES.len(), 24);
    }

    #[test]
    fn broadcast_type_serde_roundtrip() {
        for &variant in ALL_BROADCAST_EVENT_TYPES {
            let json = serde_json::to_string(&variant).unwrap();
            let deserialized: BroadcastEventType = serde_json::from_str(&json).unwrap();
            assert_eq!(variant, deserialized, "roundtrip failed for {json}");
        }
    }

    #[test]
    fn broadcast_type_exact_strings() {
        let expected = [
            (BroadcastEventType::SessionCreated, "session.created"),
            (BroadcastEventType::SessionEnded, "session.ended"),
            (BroadcastEventType::SessionForked, "session.forked"),
            (BroadcastEventType::SessionRewound, "session.rewound"),
            (BroadcastEventType::AgentTurn, "agent.turn"),
            (BroadcastEventType::AgentMessageDeleted, "agent.message_deleted"),
            (BroadcastEventType::AgentContextCleared, "agent.context_cleared"),
            (BroadcastEventType::AgentCompaction, "agent.compaction"),
            (BroadcastEventType::AgentMemoryUpdating, "agent.memory_updating"),
            (BroadcastEventType::AgentMemoryUpdated, "agent.memory_updated"),
            (BroadcastEventType::AgentSkillRemoved, "agent.skill_removed"),
            (BroadcastEventType::AgentTodosUpdated, "agent.todos_updated"),
            (BroadcastEventType::TaskCreated, "task.created"),
            (BroadcastEventType::TaskUpdated, "task.updated"),
            (BroadcastEventType::TaskDeleted, "task.deleted"),
            (BroadcastEventType::ProjectCreated, "project.created"),
            (BroadcastEventType::ProjectUpdated, "project.updated"),
            (BroadcastEventType::ProjectDeleted, "project.deleted"),
            (BroadcastEventType::AreaCreated, "area.created"),
            (BroadcastEventType::AreaUpdated, "area.updated"),
            (BroadcastEventType::AreaDeleted, "area.deleted"),
            (BroadcastEventType::BrowserFrame, "browser.frame"),
            (BroadcastEventType::BrowserClosed, "browser.closed"),
            (BroadcastEventType::EventNew, "event.new"),
        ];

        for (variant, expected_str) in expected {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(json, format!("\"{expected_str}\""), "wrong string for {variant:?}");
        }
    }

    #[test]
    fn broadcast_type_rejects_invalid() {
        let result = serde_json::from_str::<BroadcastEventType>("\"not.a.type\"");
        assert!(result.is_err());
    }

    // ── EventEnvelope ────────────────────────────────────────────────

    #[test]
    fn envelope_serde_roundtrip() {
        let envelope = EventEnvelope {
            event_type: "event.new".to_string(),
            session_id: Some("sess_123".to_string()),
            timestamp: "2025-01-15T10:00:00Z".to_string(),
            data: serde_json::json!({"id": "evt_1", "type": "message.user"}),
        };

        let json = serde_json::to_string(&envelope).unwrap();
        let deserialized: EventEnvelope = serde_json::from_str(&json).unwrap();

        assert_eq!(deserialized.event_type, "event.new");
        assert_eq!(deserialized.session_id.as_deref(), Some("sess_123"));
        assert_eq!(deserialized.timestamp, "2025-01-15T10:00:00Z");
        assert_eq!(deserialized.data["id"], "evt_1");
    }

    #[test]
    fn envelope_omits_null_session_id() {
        let envelope = EventEnvelope {
            event_type: "browser.closed".to_string(),
            session_id: None,
            timestamp: "2025-01-15T10:00:00Z".to_string(),
            data: serde_json::json!({}),
        };

        let json = serde_json::to_string(&envelope).unwrap();
        assert!(!json.contains("sessionId"), "sessionId should be omitted when None");
    }

    #[test]
    fn envelope_json_field_names() {
        let envelope = EventEnvelope {
            event_type: "session.created".to_string(),
            session_id: Some("sess_1".to_string()),
            timestamp: "2025-01-15T10:00:00Z".to_string(),
            data: serde_json::json!({}),
        };

        let val: Value = serde_json::to_value(&envelope).unwrap();
        assert!(val.get("type").is_some(), "should use 'type' not 'event_type'");
        assert!(val.get("sessionId").is_some(), "should use camelCase 'sessionId'");
        assert!(val.get("timestamp").is_some());
        assert!(val.get("data").is_some());
    }

    // ── create_event_envelope ────────────────────────────────────────

    #[test]
    fn create_envelope_with_explicit_session_id() {
        let envelope = create_event_envelope(
            "event.new",
            serde_json::json!({"id": "evt_1"}),
            Some("sess_1"),
        );

        assert_eq!(envelope.event_type, "event.new");
        assert_eq!(envelope.session_id.as_deref(), Some("sess_1"));
        assert!(!envelope.timestamp.is_empty());
    }

    #[test]
    fn create_envelope_extracts_session_id_from_data() {
        let envelope = create_event_envelope(
            "event.new",
            serde_json::json!({"sessionId": "sess_from_data"}),
            None,
        );

        assert_eq!(envelope.session_id.as_deref(), Some("sess_from_data"));
    }

    #[test]
    fn create_envelope_explicit_session_id_overrides_data() {
        let envelope = create_event_envelope(
            "event.new",
            serde_json::json!({"sessionId": "sess_from_data"}),
            Some("sess_explicit"),
        );

        assert_eq!(envelope.session_id.as_deref(), Some("sess_explicit"));
    }

    #[test]
    fn create_envelope_no_session_id() {
        let envelope = create_event_envelope(
            "browser.closed",
            serde_json::json!({}),
            None,
        );

        assert!(envelope.session_id.is_none());
    }

    #[test]
    fn create_envelope_preserves_data_timestamp() {
        let envelope = create_event_envelope(
            "event.new",
            serde_json::json!({"timestamp": "2025-01-15T10:00:00Z"}),
            None,
        );

        assert_eq!(envelope.timestamp, "2025-01-15T10:00:00Z");
    }

    #[test]
    fn create_envelope_generates_timestamp_when_absent() {
        let envelope = create_event_envelope(
            "event.new",
            serde_json::json!({"id": "evt_1"}),
            None,
        );

        assert!(!envelope.timestamp.is_empty());
        // Should be a valid ISO 8601 timestamp
        assert!(envelope.timestamp.contains('T'));
    }
}
