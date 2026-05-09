//! Public data types for the Prompt Library.

use serde::{Deserialize, Serialize};

/// A single prompt-history entry.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItem {
    /// Primary-key UUID v7.
    pub id: String,
    /// Original (display) text — trimmed, but not NFC-normalized.
    pub text: String,
    /// ISO-8601 UTC timestamp when this prompt was first recorded.
    pub first_used_at: String,
    /// ISO-8601 UTC timestamp of the most recent occurrence.
    pub last_used_at: String,
    /// Number of times this normalized prompt has been sent.
    pub use_count: i64,
    /// Character count of `text` (display form).
    pub char_count: i64,
}

/// One page of history results with an opaque cursor.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPage {
    /// The page's entries, newest first.
    pub items: Vec<HistoryItem>,
    /// Opaque cursor for the next page, or `None` when exhausted.
    pub next_cursor: Option<String>,
}

/// Outcome of a `record_prompt` call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordOutcome {
    /// The prompt was new and a fresh row was inserted.
    Inserted {
        /// Id of the newly inserted row.
        id: String,
    },
    /// The prompt existed; `last_used_at` bumped and `use_count` incremented.
    Updated {
        /// Id of the existing row.
        id: String,
        /// New use count after the increment.
        use_count: i64,
    },
    /// The input was blank/whitespace-only and ignored.
    Skipped,
}

/// A user-authored snippet.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    /// Primary-key UUID v7.
    pub id: String,
    /// Display name (1–100 chars).
    pub name: String,
    /// Prompt body (non-empty, up to `MAX_PROMPT_LENGTH`).
    pub text: String,
    /// ISO-8601 UTC timestamp of creation.
    pub created_at: String,
    /// ISO-8601 UTC timestamp of most recent mutation.
    pub updated_at: String,
}
