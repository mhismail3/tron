//! Metadata event payloads.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `metadata.update` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataUpdatePayload {
    /// Metadata key.
    pub key: String,
    /// Previous value.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_value: Option<Value>,
    /// New value.
    pub new_value: Value,
}

/// Payload for `metadata.tag` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataTagPayload {
    /// Action: "add" or "remove".
    pub action: String,
    /// Tag value.
    pub tag: String,
}
