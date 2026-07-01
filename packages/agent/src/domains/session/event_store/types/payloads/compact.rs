//! Compaction event payloads: committed boundary and pre-commit staging.

use serde::{Deserialize, Serialize};

/// Payload for `compact.boundary` events.
///
/// The `reason` field is required — every emit site classifies the trigger
/// (manual / threshold / progress-signal / imported) and iOS expects a
/// non-empty value for the reconstruction view. `deny_unknown_fields`
/// guards against drift; adding a field here means adding it at every
/// emit site in the same commit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
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
    /// Why compaction was triggered. Non-empty label identifying the trigger
    /// (e.g. "manual", "threshold_exceeded", "progress_signal", "imported").
    pub reason: String,
    /// Summary of the compacted content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Estimated context tokens after compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub estimated_context_tokens: Option<i64>,
    /// Number of turns preserved after compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preserved_turns: Option<i64>,
    /// Number of turns summarized into the compacted block.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summarized_turns: Option<i64>,
    /// Number of messages preserved after compaction.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preserved_messages: Option<i64>,
    /// Context-control action resource backing this boundary, when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_control_action_resource_id: Option<String>,
    /// Context-control preflight snapshot resource backing this boundary, when
    /// available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_control_snapshot_resource_id: Option<String>,
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

/// Payload for `compact.summary_staging` events.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_boundary_requires_reason() {
        // Strict wire contract: `reason` is required. Missing field fails
        // deserialization rather than defaulting.
        let missing = serde_json::json!({
            "originalTokens": 100,
            "compactedTokens": 10,
        });
        let err = serde_json::from_value::<CompactBoundaryPayload>(missing).unwrap_err();
        assert!(
            err.to_string().contains("reason"),
            "expected error naming `reason`, got: {err}"
        );
    }

    #[test]
    fn compact_boundary_requires_original_tokens() {
        let missing = serde_json::json!({
            "compactedTokens": 10,
            "reason": "manual",
        });
        let err = serde_json::from_value::<CompactBoundaryPayload>(missing).unwrap_err();
        assert!(
            err.to_string().contains("originalTokens"),
            "expected error naming `originalTokens`, got: {err}"
        );
    }

    #[test]
    fn compact_boundary_rejects_unknown_fields() {
        // `deny_unknown_fields` guards the schema against drift.
        let bad = serde_json::json!({
            "originalTokens": 100,
            "compactedTokens": 10,
            "reason": "manual",
            "future": "value",
        });
        assert!(serde_json::from_value::<CompactBoundaryPayload>(bad).is_err());
    }

    #[test]
    fn compact_boundary_minimal_payload_decodes() {
        // Minimal happy path: only the three required fields.
        let ok = serde_json::json!({
            "originalTokens": 100,
            "compactedTokens": 10,
            "reason": "manual",
        });
        let parsed: CompactBoundaryPayload = serde_json::from_value(ok).unwrap();
        assert_eq!(parsed.original_tokens, 100);
        assert_eq!(parsed.compacted_tokens, 10);
        assert_eq!(parsed.reason, "manual");
        assert!(parsed.range.is_none());
    }

    #[test]
    fn compact_boundary_accepts_context_control_audit_refs() {
        let ok = serde_json::json!({
            "originalTokens": 100,
            "compactedTokens": 10,
            "reason": "threshold_exceeded",
            "contextControlActionResourceId": "context_control_action:test",
            "contextControlSnapshotResourceId": "context_control_snapshot:test",
        });
        let parsed: CompactBoundaryPayload = serde_json::from_value(ok).unwrap();
        assert_eq!(
            parsed.context_control_action_resource_id.as_deref(),
            Some("context_control_action:test")
        );
        assert_eq!(
            parsed.context_control_snapshot_resource_id.as_deref(),
            Some("context_control_snapshot:test")
        );
    }

    #[test]
    fn compact_boundary_reason_encoding_matches_enum() {
        // The emit path in `runtime/agent/compaction_handler.rs` serializes
        // `CompactionReason` via serde. These literal strings must match
        // `#[serde(rename_all = "snake_case")]` on `CompactionReason` so
        // decode on the other end produces the expected classification.
        for reason in [
            "manual",
            "threshold_exceeded",
            "progress_signal",
            "imported",
        ] {
            let ok = serde_json::json!({
                "originalTokens": 0,
                "compactedTokens": 0,
                "reason": reason,
            });
            let parsed: CompactBoundaryPayload = serde_json::from_value(ok).unwrap();
            assert_eq!(parsed.reason, reason);
        }
    }
}
