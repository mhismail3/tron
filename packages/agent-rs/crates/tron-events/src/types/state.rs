//! State types for sessions, workspaces, and search results.
//!
//! These match the TypeScript `state.ts` types for wire compatibility.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::generated::EventType;
use super::payloads::TokenUsage;

/// A reconstructed message from the event history.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    /// Message role.
    pub role: String,
    /// Message content (string for user/system, array for assistant).
    pub content: Value,
    /// Tool call ID (for `toolResult` messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Whether this is an error result.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

/// A message with its source event IDs.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageWithEventId {
    /// The reconstructed message.
    pub message: Message,
    /// Source event IDs (multiple when messages are merged).
    pub event_ids: Vec<Option<String>>,
}

/// Full state of a session at a given point.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    /// Session ID.
    pub session_id: String,
    /// Workspace ID.
    pub workspace_id: String,
    /// Head event ID.
    pub head_event_id: String,
    /// Current model.
    pub model: String,
    /// Working directory.
    pub working_directory: String,
    /// Reconstructed messages.
    pub messages_with_event_ids: Vec<MessageWithEventId>,
    /// Aggregate token usage.
    pub token_usage: TokenUsage,
    /// Number of completed turns.
    pub turn_count: i64,
    /// Provider name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// Current system prompt.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// Reasoning level.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_level: Option<String>,
    /// Session metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<SessionMetadata>,
    /// Whether the session has ended.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_ended: Option<bool>,
    /// Branch info.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub branch: Option<BranchRef>,
    /// Timestamp of the state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
}

/// Session metadata.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMetadata {
    /// Session title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Tags.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Creation timestamp.
    pub created: String,
    /// Last activity timestamp.
    pub last_activity: String,
    /// Fork source.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forked_from: Option<ForkRef>,
    /// Custom metadata.
    #[serde(default)]
    pub custom: Value,
}

/// Fork reference in session metadata.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForkRef {
    /// Source session ID.
    pub session_id: String,
    /// Source event ID.
    pub event_id: String,
}

/// Branch reference.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BranchRef {
    /// Branch ID.
    pub id: String,
    /// Branch name.
    pub name: String,
}

/// Branch state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Branch {
    /// Branch ID.
    pub id: String,
    /// Branch name.
    pub name: String,
    /// Session ID.
    pub session_id: String,
    /// Root event ID.
    pub root_event_id: String,
    /// Head event ID.
    pub head_event_id: String,
    /// Event count.
    pub event_count: i64,
    /// Creation timestamp.
    pub created: String,
    /// Last activity timestamp.
    pub last_activity: String,
    /// Whether this is the default branch.
    pub is_default: bool,
}

/// Session summary (lightweight, for list views).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    /// Session ID.
    pub session_id: String,
    /// Workspace ID.
    pub workspace_id: String,
    /// Session title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Event count.
    pub event_count: i64,
    /// Message count.
    pub message_count: i64,
    /// Branch count.
    pub branch_count: i64,
    /// Aggregate token usage.
    pub token_usage: TokenUsage,
    /// Creation timestamp.
    pub created: String,
    /// Last activity timestamp.
    pub last_activity: String,
    /// Whether the session has ended.
    pub is_ended: bool,
    /// Tags.
    #[serde(default)]
    pub tags: Vec<String>,
}

/// Workspace info.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    /// Workspace ID.
    pub id: String,
    /// Absolute path.
    pub path: String,
    /// Display name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Creation timestamp.
    pub created: String,
    /// Last activity timestamp.
    pub last_activity: String,
    /// Number of sessions.
    pub session_count: i64,
}

/// Search result from FTS5 search.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    /// Event ID.
    pub event_id: String,
    /// Session ID.
    pub session_id: String,
    /// Event type.
    #[serde(rename = "type")]
    pub event_type: EventType,
    /// Timestamp.
    pub timestamp: String,
    /// Highlighted snippet.
    pub snippet: String,
    /// BM25 relevance score.
    pub score: f64,
}
