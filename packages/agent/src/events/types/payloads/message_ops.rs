//! Message operation payloads.

use serde::{Deserialize, Serialize};

/// Payload for `message.deleted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageDeletedPayload {
    /// Event ID of the message being deleted.
    pub target_event_id: String,
    /// Type of the target message.
    pub target_type: String,
    /// Turn number of the deleted message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_turn: Option<i64>,
    /// Reason for deletion.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}
