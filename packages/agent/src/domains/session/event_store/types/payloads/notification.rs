//! Notification event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `notification.interrupted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationInterruptedPayload {
    /// Timestamp.
    pub timestamp: String,
    /// Turn at which interruption occurred.
    pub turn: i64,
}

/// Payload for `notification.process_result` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationProcessResultPayload {
    /// Session that owns the process.
    pub parent_session_id: String,
    /// Process identifier.
    pub process_id: String,
    /// Human-readable label (command text).
    pub label: String,
    /// Result summary (truncated output).
    pub result_summary: String,
    /// Whether the process completed successfully.
    pub success: bool,
    /// Exit code (None for non-shell processes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Completion timestamp.
    pub completed_at: String,
    /// Blob ID for full output (if large).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_id: Option<String>,
    /// Truncated output for context injection (max 4000 chars).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
}

/// Payload for `process.results_consumed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessResultsConsumedPayload {
    /// IDs of the `notification.process_result` events that were consumed.
    pub consumed_event_ids: Vec<String>,
    /// Number of results consumed.
    pub count: usize,
}

/// Payload for `user_job_actions.consumed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserJobActionsConsumedPayload {
    /// IDs of the consumed `notification.user_job_action` events.
    pub consumed_event_ids: Vec<String>,
    /// Number of actions consumed.
    pub count: usize,
}

/// Payload for `notification.user_job_action` events.
///
/// Persisted when the user backgrounds or cancels a job from the iOS app.
/// Picked up by the turn runner for system message injection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserJobActionPayload {
    /// Job identifier (process ID or subagent session ID).
    pub job_id: String,
    /// Action taken: `"backgrounded"` or `"cancelled"`.
    pub action: String,
    /// Human-readable label (command text).
    pub label: String,
}
