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
    /// Capability invocation ID.
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
    /// Capability invocation ID.
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

/// Payload for `hook.llm_result` events.
///
/// Records the result of an LLM-based hook execution (prompt hook).
/// Persisted to the parent session's event store as an audit trail.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LlmHookResultPayload {
    /// Hook name/label.
    pub hook_name: String,
    /// Hook definition ID.
    pub hook_id: String,
    /// Lifecycle event that triggered this hook (e.g., "sessionStart").
    pub hook_event: String,
    /// LLM output text (truncated to 1KB).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Duration of the LLM call in milliseconds.
    pub duration_ms: u64,
    /// Model used for the LLM call.
    pub model: String,
    /// Input tokens consumed.
    pub input_tokens: u64,
    /// Output tokens consumed.
    pub output_tokens: u64,
    /// Whether the hook completed successfully.
    pub success: bool,
    /// Error message if the hook failed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Structured suggestions parsed from suggest-prompts hook output.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub suggestions: Option<Vec<String>>,
    /// Timestamp.
    pub timestamp: String,
}
