//! Context event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `context.cleared` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextClearedPayload {
    /// Token count before clearing.
    pub tokens_before: i64,
    /// Token count after clearing.
    pub tokens_after: i64,
    /// Reason for clearing.
    pub reason: String,
    /// Internal invocation that caused this boundary, retained as durable
    /// audit correlation. Reconstruction derives provider-valid result pairing
    /// from the surviving assistant invocation blocks instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub boundary_invocation_id: Option<String>,
}
