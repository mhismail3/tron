//! Compaction event payloads: boundary, summary.

use serde::{Deserialize, Serialize};

/// Payload for `compact.boundary` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactBoundaryPayload {
    /// Event range that was compacted (absent for auto-compaction).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<CompactRange>,
    /// Token count of the original messages.
    pub original_tokens: i64,
    /// Token count after compaction.
    pub compacted_tokens: i64,
    /// Compression ratio (tokensAfter / tokensBefore).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compression_ratio: Option<f64>,
    /// Why compaction was triggered.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Summary of the compacted content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Estimated context tokens after compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_context_tokens: Option<i64>,
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

/// Payload for `compact.summary_staging` events (H13 two-phase commit).
///
/// Phase 1 of the compaction two-phase commit: written right after the
/// summarizer returns its output and BEFORE the boundary commit. Carries
/// the produced summary durably so the LLM's work is preserved even if
/// the boundary persist later fails.
///
/// Reconstruction ignores a staging event that lacks a matching
/// [`CompactBoundaryPayload`]; the boundary is the authoritative commit
/// point. On startup, a janitor removes staging rows that are older than
/// the configured age without a successor boundary event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactSummaryStagingPayload {
    /// Token count of the original messages (copied into the boundary on commit).
    pub original_tokens: i64,
    /// Expected token count after applying this staged summary.
    pub compacted_tokens: i64,
    /// Why compaction was triggered.
    pub reason: String,
    /// The summary text produced by the summarizer. The boundary on commit
    /// gets the same text so reconstruction needs to read only the boundary.
    pub summary: String,
    /// ISO 8601 timestamp of when the staging event was written.
    pub timestamp: String,
}
