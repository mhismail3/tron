//! Memory event payloads.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `memory.ledger` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryLedgerPayload {
    /// Event range covered.
    pub event_range: EventRange,
    /// Turn range covered.
    pub turn_range: TurnRange,
    /// Session title.
    pub title: String,
    /// Entry type.
    pub entry_type: String,
    /// Completion status.
    pub status: String,
    /// Tags.
    pub tags: Vec<String>,
    /// Original user input/request.
    pub input: String,
    /// Actions taken.
    pub actions: Vec<String>,
    /// Files modified.
    pub files: Vec<LedgerFileEntry>,
    /// Decisions made.
    pub decisions: Vec<LedgerDecision>,
    /// Lessons learned.
    pub lessons: Vec<String>,
    /// Insights from thinking blocks.
    pub thinking_insights: Vec<String>,
    /// Token costs.
    pub token_cost: LedgerTokenCost,
    /// Model used.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
}

/// Event ID range.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventRange {
    /// First event ID.
    pub first_event_id: String,
    /// Last event ID.
    pub last_event_id: String,
}

/// Turn number range.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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
