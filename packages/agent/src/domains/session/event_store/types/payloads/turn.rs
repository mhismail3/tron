//! Turn event payloads.

use serde::{Deserialize, Serialize};
use serde_json::Value;

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
    /// Whether retrying the same request may succeed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retryable: Option<bool>,
    /// Whether the error is recoverable.
    pub recoverable: bool,
    /// Layer that classified the failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    /// Structured failure details. New runtime rows include
    /// `details.failure`, the canonical failure envelope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
    /// Content generated before failure.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial_content: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn turn_failed_payload_preserves_canonical_failure_details() {
        let raw = json!({
            "turn": 3,
            "error": "Interrupted by user",
            "code": "RUNTIME_CANCELLED",
            "category": "cancelled",
            "retryable": false,
            "recoverable": true,
            "origin": "agent_runtime",
            "details": {
                "failure": {
                    "code": "RUNTIME_CANCELLED",
                    "category": "cancelled",
                    "message": "Interrupted by user",
                    "retryable": false,
                    "recoverable": true,
                    "origin": "agent_runtime"
                }
            },
            "partialContent": null
        });

        let payload: TurnFailedPayload = serde_json::from_value(raw).unwrap();

        assert_eq!(payload.code.as_deref(), Some("RUNTIME_CANCELLED"));
        assert_eq!(payload.category.as_deref(), Some("cancelled"));
        assert_eq!(payload.retryable, Some(false));
        assert_eq!(payload.origin.as_deref(), Some("agent_runtime"));
        assert_eq!(
            payload.details.unwrap()["failure"]["code"],
            "RUNTIME_CANCELLED"
        );
    }
}
