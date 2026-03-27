//! Memory event payloads: retained.

use serde::{Deserialize, Serialize};

/// Payload for `memory.retained` events.
///
/// Marks the boundary in the event stream for the next Retain operation,
/// so it knows where the previous summarization window ended.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRetainedPayload {
    /// Session ID this retain belongs to.
    pub session_id: String,
    /// Turn number at time of retain.
    pub turn_number: i64,
    /// First line of the summary (used as title in UI).
    pub title: String,
    /// Full summary text from the LLM summarizer.
    pub summary: String,
    /// ISO 8601 timestamp.
    pub timestamp: String,
}
