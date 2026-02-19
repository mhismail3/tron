//! Hook event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `hook.triggered` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookTriggeredPayload {
    /// Hook names.
    pub hook_names: Vec<String>,
    /// Hook event type (e.g., `PreToolUse`).
    pub hook_event: String,
    /// Tool name (for tool-related hooks).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// Tool call ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Timestamp.
    pub timestamp: String,
}

/// Payload for `hook.completed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookCompletedPayload {
    /// Hook names.
    pub hook_names: Vec<String>,
    /// Hook event type.
    pub hook_event: String,
    /// Result action.
    pub result: String,
    /// Duration in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<i64>,
    /// Reason for block/modify.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Tool name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
    /// Tool call ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Timestamp.
    pub timestamp: String,
}

/// Payload for `hook.background_started` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookBackgroundStartedPayload {
    /// Hook names.
    pub hook_names: Vec<String>,
    /// Hook event type.
    pub hook_event: String,
    /// Correlation ID.
    pub execution_id: String,
    /// Timestamp.
    pub timestamp: String,
}

/// Payload for `hook.background_completed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookBackgroundCompletedPayload {
    /// Hook names.
    pub hook_names: Vec<String>,
    /// Hook event type.
    pub hook_event: String,
    /// Correlation ID.
    pub execution_id: String,
    /// Result.
    pub result: String,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Error message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Timestamp.
    pub timestamp: String,
}
