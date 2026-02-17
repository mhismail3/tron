//! Notification event payloads.

use serde::{Deserialize, Serialize};

use super::TokenUsage;

/// Payload for `notification.interrupted` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationInterruptedPayload {
    /// Timestamp.
    pub timestamp: String,
    /// Turn at which interruption occurred.
    pub turn: i64,
}

/// Payload for `notification.subagent_result` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationSubagentResultPayload {
    /// Parent session ID.
    pub parent_session_id: String,
    /// Child session ID.
    pub subagent_session_id: String,
    /// Task description.
    pub task: String,
    /// Result summary.
    pub result_summary: String,
    /// Whether the subagent succeeded.
    pub success: bool,
    /// Total turns taken.
    pub total_turns: i64,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Token usage.
    pub token_usage: TokenUsage,
    /// Completion timestamp.
    pub completed_at: String,
    /// Warning message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
    /// Full output from the subagent (truncated for context injection).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
}

/// Payload for `subagent.results_consumed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentResultsConsumedPayload {
    /// IDs of the notification.subagent_result events that were consumed.
    pub consumed_event_ids: Vec<String>,
    /// Number of results consumed.
    pub count: usize,
}
