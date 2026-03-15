//! Memory event payloads.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

/// Deserialize a value that may be JSON `null` as `T::default()`.
///
/// Combined with `#[serde(default)]` at the struct level, this handles both
/// missing fields (struct default) and explicit `null` values (this helper).
/// Used for backfill-imported payloads that may have null or missing fields.
fn null_to_default<'de, D, T>(deserializer: D) -> std::result::Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Default + Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(std::option::Option::unwrap_or_default)
}

/// Payload for `memory.ledger` events.
///
/// Tolerant of missing and null fields to support both server-generated payloads
/// (all fields populated) and backfill-imported payloads (subset of fields, others null).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MemoryLedgerPayload {
    /// Event range covered.
    #[serde(deserialize_with = "null_to_default")]
    pub event_range: EventRange,
    /// Turn range covered.
    #[serde(deserialize_with = "null_to_default")]
    pub turn_range: TurnRange,
    /// Session title.
    #[serde(deserialize_with = "null_to_default")]
    pub title: String,
    /// Entry type.
    #[serde(deserialize_with = "null_to_default")]
    pub entry_type: String,
    /// Completion status.
    #[serde(deserialize_with = "null_to_default")]
    pub status: String,
    /// Tags.
    #[serde(deserialize_with = "null_to_default")]
    pub tags: Vec<String>,
    /// Original user input/request.
    #[serde(deserialize_with = "null_to_default")]
    pub input: String,
    /// Actions taken.
    #[serde(deserialize_with = "null_to_default")]
    pub actions: Vec<String>,
    /// Files modified.
    #[serde(deserialize_with = "null_to_default")]
    pub files: Vec<LedgerFileEntry>,
    /// Decisions made.
    #[serde(deserialize_with = "null_to_default")]
    pub decisions: Vec<LedgerDecision>,
    /// Lessons learned.
    #[serde(deserialize_with = "null_to_default")]
    pub lessons: Vec<String>,
    /// Insights from thinking blocks.
    #[serde(deserialize_with = "null_to_default")]
    pub thinking_insights: Vec<String>,
    /// Token costs.
    #[serde(deserialize_with = "null_to_default")]
    pub token_cost: LedgerTokenCost,
    /// Model used.
    #[serde(deserialize_with = "null_to_default")]
    pub model: String,
    /// Working directory.
    #[serde(deserialize_with = "null_to_default")]
    pub working_directory: String,
    /// Origin of the ledger write (`auto`, `manual`, `cron`, etc.).
    #[serde(deserialize_with = "null_to_default")]
    pub source: String,
}

/// Event ID range.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventRange {
    /// First event ID.
    pub first_event_id: String,
    /// Last event ID.
    pub last_event_id: String,
}

/// Turn number range.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnRange {
    /// First turn number.
    pub first_turn: i64,
    /// Last turn number.
    pub last_turn: i64,
}

/// File entry in a ledger record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LedgerFileEntry {
    /// File path.
    pub path: String,
    /// Operation: C (create), M (modify), D (delete).
    pub op: String,
    /// Purpose description.
    pub why: String,
}

/// Decision in a ledger record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LedgerDecision {
    /// What was chosen.
    pub choice: String,
    /// Why it was chosen.
    pub reason: String,
}

/// Token cost in a ledger record.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct LedgerTokenCost {
    /// Input tokens.
    pub input: i64,
    /// Output tokens.
    pub output: i64,
}

/// Payload for `memory.loaded` events.
///
/// Kept as opaque JSON since the schema is flexible.
pub type MemoryLoadedPayload = Value;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_payload_roundtrip() {
        let payload = MemoryLedgerPayload {
            event_range: EventRange {
                first_event_id: "e1".into(),
                last_event_id: "e2".into(),
            },
            turn_range: TurnRange {
                first_turn: 1,
                last_turn: 3,
            },
            title: "Test".into(),
            entry_type: "feature".into(),
            status: "completed".into(),
            tags: vec!["a".into()],
            input: "do thing".into(),
            actions: vec!["did it".into()],
            files: vec![LedgerFileEntry {
                path: "f.rs".into(),
                op: "M".into(),
                why: "fix".into(),
            }],
            decisions: vec![LedgerDecision {
                choice: "X".into(),
                reason: "Y".into(),
            }],
            lessons: vec!["lesson".into()],
            thinking_insights: vec!["insight".into()],
            token_cost: LedgerTokenCost {
                input: 100,
                output: 50,
            },
            model: "claude".into(),
            working_directory: "/tmp".into(),
            source: "manual".into(),
        };
        let json = serde_json::to_value(&payload).unwrap();
        let back: MemoryLedgerPayload = serde_json::from_value(json).unwrap();
        assert_eq!(payload, back);
    }

    #[test]
    fn backfill_payload_with_nulls() {
        // Mimics what tron-backfill import creates when LEDGER fields are None
        let json = serde_json::json!({
            "title": "Session title",
            "input": "user request",
            "actions": ["did thing"],
            "lessons": ["learned stuff"],
            "decisions": null,
            "tags": null,
            "entryType": "feature",
            "status": "completed",
            "timestamp": "2026-01-01T00:00:00Z",
            "_meta": { "source": "ledger.jsonl", "id": "abc" }
        });
        let payload: MemoryLedgerPayload = serde_json::from_value(json).unwrap();
        assert_eq!(payload.title, "Session title");
        assert_eq!(payload.input, "user request");
        assert_eq!(payload.actions, vec!["did thing"]);
        assert_eq!(payload.lessons, vec!["learned stuff"]);
        assert!(payload.decisions.is_empty());
        assert!(payload.tags.is_empty());
        assert_eq!(payload.entry_type, "feature");
        // Missing fields get defaults
        assert_eq!(payload.event_range, EventRange::default());
        assert_eq!(payload.turn_range, TurnRange::default());
        assert_eq!(payload.token_cost, LedgerTokenCost::default());
        assert!(payload.model.is_empty());
        assert!(payload.working_directory.is_empty());
        assert!(payload.source.is_empty());
    }

    #[test]
    fn backfill_payload_all_nulls() {
        let json = serde_json::json!({
            "title": null,
            "input": null,
            "actions": null,
            "lessons": null,
            "decisions": null,
            "tags": null,
            "entryType": null,
            "status": null,
        });
        let payload: MemoryLedgerPayload = serde_json::from_value(json).unwrap();
        assert!(payload.title.is_empty());
        assert!(payload.input.is_empty());
        assert!(payload.actions.is_empty());
        assert!(payload.lessons.is_empty());
    }

    #[test]
    fn empty_json_object() {
        let json = serde_json::json!({});
        let payload: MemoryLedgerPayload = serde_json::from_value(json).unwrap();
        assert_eq!(payload, MemoryLedgerPayload::default());
    }
}
