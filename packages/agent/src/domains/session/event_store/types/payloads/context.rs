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
    /// Context-control action resource backing this clear boundary, when
    /// available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_control_action_resource_id: Option<String>,
    /// Context-control preflight snapshot resource backing this clear boundary,
    /// when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_control_snapshot_resource_id: Option<String>,
}
