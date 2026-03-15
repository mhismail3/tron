//! Config event payloads: model switch, prompt update, reasoning level.

use serde::{Deserialize, Serialize};

/// Payload for `config.model_switch` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigModelSwitchPayload {
    /// Previous model ID.
    pub previous_model: String,
    /// New model ID.
    pub new_model: String,
    /// Switch reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Payload for `config.prompt_update` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigPromptUpdatePayload {
    /// Hash of the previous prompt content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_hash: Option<String>,
    /// Hash of the new prompt content.
    pub new_hash: String,
    /// Blob ID storing the content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_blob_id: Option<String>,
}

/// Payload for `config.reasoning_level` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigReasoningLevelPayload {
    /// Previous reasoning level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_level: Option<String>,
    /// New reasoning level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_level: Option<String>,
}
