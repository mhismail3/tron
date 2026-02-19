//! The [`SessionEvent`] struct — the core persisted event type.
//!
//! Events are stored as a flat struct with base fields at the top level
//! and a `payload` stored as opaque [`serde_json::Value`]. This matches
//! the TypeScript storage format exactly for wire compatibility.
//!
//! Typed access to the payload is opt-in via [`SessionEvent::typed_payload()`],
//! which dispatches on [`EventType`] and deserializes into the appropriate
//! payload struct.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::generated::EventType;

/// A persisted session event.
///
/// The canonical wire format has base fields (`id`, `parentId`, `sessionId`,
/// etc.) at the top level and a `payload` JSON object. The payload is stored
/// as opaque `serde_json::Value` for exact wire compatibility.
///
/// Use [`typed_payload()`](Self::typed_payload) for compile-time-safe payload access.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEvent {
    /// Unique event ID (UUID v7).
    pub id: String,
    /// Parent event ID (`null` for root events).
    pub parent_id: Option<String>,
    /// Session this event belongs to.
    pub session_id: String,
    /// Workspace this event belongs to.
    pub workspace_id: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
    /// Event type discriminator.
    #[serde(rename = "type")]
    pub event_type: EventType,
    /// Monotonic sequence number within the session.
    pub sequence: i64,
    /// Integrity checksum.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checksum: Option<String>,
    /// Event-specific data (opaque JSON).
    pub payload: Value,
}
