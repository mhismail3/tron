//! Memory event payloads: retained, auto-retain triggered.

use serde::{Deserialize, Serialize};

/// Payload for `memory.retained` events.
///
/// Marks the boundary in the event stream for the next Retain operation —
/// the event's own sequence number IS the boundary, so no turn-count field
/// is needed here.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRetainedPayload {
    /// Session ID this retain belongs to.
    pub session_id: String,
    /// First line of the summary (used as title in UI).
    pub title: String,
    /// Full summary text from the LLM summarizer.
    pub summary: String,
    /// ISO 8601 timestamp when the retain completed.
    pub timestamp: String,
}

/// Payload for `memory.auto_retain_triggered` events.
///
/// Emitted once, immediately before the auto-retain pipeline starts. Lets
/// iOS distinguish automatic retentions (fired by the server hitting the
/// `memory.autoRetainInterval` threshold) from manual retentions (user hit
/// the Retain button). The summary itself still lands in a `memory.retained`
/// event after the summarizer completes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryAutoRetainTriggeredPayload {
    /// Session ID this auto-retain belongs to.
    pub session_id: String,
    /// The `memory.autoRetainInterval` value that caused the fire.
    pub interval_fired: u32,
    /// ISO 8601 timestamp.
    pub timestamp: String,
}
