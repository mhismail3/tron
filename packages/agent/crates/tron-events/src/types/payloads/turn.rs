//! Turn event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `turn.failed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TurnFailedPayload {
    /// Turn number.
    pub turn: i64,
    /// Error message.
    pub error: String,
    /// Error code (e.g., "PAUTH", "PRATE", "NET", "CTX").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error category.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    /// Whether the error is recoverable.
    pub recoverable: bool,
    /// Content generated before failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial_content: Option<String>,
}
