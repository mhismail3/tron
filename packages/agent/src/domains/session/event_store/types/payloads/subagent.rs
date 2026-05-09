//! Subagent event payloads.

use serde::{Deserialize, Serialize};

use super::TokenUsage;

/// Payload for `subagent.spawned` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentSpawnedPayload {
    /// Child session ID.
    pub subagent_session_id: String,
    /// Spawn type.
    pub spawn_type: String,
    /// Task description.
    pub task: String,
    /// Model ID.
    pub model: String,
    /// Tools available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<String>>,
    /// Skills available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<String>>,
    /// Working directory.
    pub working_directory: String,
    /// Tmux session name for tmux spawn type.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session_name: Option<String>,
    /// Maximum turns allowed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_turns: Option<i64>,
}

/// Payload for `subagent.status_update` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentStatusUpdatePayload {
    /// Child session ID.
    pub subagent_session_id: String,
    /// Current status.
    pub status: String,
    /// Current turn number.
    pub current_turn: i64,
    /// Activity description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity: Option<String>,
    /// Token usage so far.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
}

/// Payload for `subagent.completed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentCompletedPayload {
    /// Child session ID.
    pub subagent_session_id: String,
    /// Result summary.
    pub result_summary: String,
    /// Total turns taken.
    pub total_turns: i64,
    /// Total token usage.
    pub total_token_usage: TokenUsage,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Files modified.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files_modified: Option<Vec<String>>,
    /// Final output text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub final_output: Option<String>,
}

/// Payload for `subagent.failed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentFailedPayload {
    /// Child session ID.
    pub subagent_session_id: String,
    /// Error message.
    pub error: String,
    /// Error code.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Whether recoverable.
    pub recoverable: bool,
    /// Partial result.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub partial_result: Option<String>,
    /// Turn at which failure occurred.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failed_at_turn: Option<i64>,
    /// Duration in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<i64>,
}
