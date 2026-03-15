//! Error event payloads: agent, tool, provider.

use serde::{Deserialize, Serialize};

/// Payload for `error.agent` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorAgentPayload {
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Whether the user can recover.
    pub recoverable: bool,
}

/// Payload for `error.tool` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorToolPayload {
    /// Tool name.
    pub tool_name: String,
    /// Tool call ID.
    pub tool_call_id: String,
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}

/// Payload for `error.provider` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorProviderPayload {
    /// Provider name.
    pub provider: String,
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error category.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    /// Suggested action.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggestion: Option<String>,
    /// Whether the error is retryable.
    pub retryable: bool,
    /// Seconds to wait before retrying.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<i64>,
}
