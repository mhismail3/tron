//! Session lifecycle payloads: start, end, fork.

use serde::{Deserialize, Serialize};

/// Payload for `session.start` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStartPayload {
    /// Absolute path to the working directory.
    pub working_directory: String,
    /// LLM model ID.
    pub model: String,
    /// Provider name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// System prompt content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// Session title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Session tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Fork source information.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forked_from: Option<ForkSource>,
}

/// Fork source reference.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ForkSource {
    /// Source session ID.
    pub session_id: String,
    /// Source event ID (fork point).
    pub event_id: String,
}

/// Payload for `session.end` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionEndPayload {
    /// End reason.
    pub reason: String,
    /// Session summary.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// Aggregate token usage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_token_usage: Option<super::TokenUsage>,
    /// Duration in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration: Option<i64>,
}

/// Payload for `session.fork` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionForkPayload {
    /// Session being forked from.
    pub source_session_id: String,
    /// Event ID at the fork point.
    pub source_event_id: String,
    /// Fork name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Reason for fork.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}
