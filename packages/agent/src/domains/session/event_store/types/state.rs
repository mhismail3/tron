//! Reconstructed session state consumed by session queries and agent restart.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::payloads::TokenUsage;

/// A reconstructed message from the event history.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    /// Message role.
    pub role: String,
    /// Message content (string for user/system, array for assistant).
    pub content: Value,
    /// Capability invocation ID (for `capabilityResult` messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invocation_id: Option<String>,
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

/// Runtime state reconstructed from a session's durable event ancestry.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionState {
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
    /// Whether the session has ended.
    pub is_ended: Option<bool>,
}
