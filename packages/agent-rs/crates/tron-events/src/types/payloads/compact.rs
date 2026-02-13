//! Compaction event payloads: boundary, summary.

use serde::{Deserialize, Serialize};

/// Payload for `compact.boundary` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactBoundaryPayload {
    /// Event range that was compacted.
    pub range: CompactRange,
    /// Token count of the original messages.
    pub original_tokens: i64,
    /// Token count after compaction.
    pub compacted_tokens: i64,
}

/// Event range for a compaction boundary.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactRange {
    /// First event in range.
    pub from: String,
    /// Last event in range.
    pub to: String,
}

/// Payload for `compact.summary` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactSummaryPayload {
    /// Compacted summary text.
    pub summary: String,
    /// Key decisions preserved.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_decisions: Option<Vec<String>>,
    /// Files modified in compacted range.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files_modified: Option<Vec<String>>,
    /// Event ID of the corresponding boundary event.
    pub boundary_event_id: String,
}
