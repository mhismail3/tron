//! Tool event payloads: call, result.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `tool.call` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallPayload {
    /// Tool call ID.
    pub tool_call_id: String,
    /// Tool name.
    pub name: String,
    /// Tool arguments.
    pub arguments: Value,
    /// Turn number.
    pub turn: i64,
}

/// Payload for `tool.result` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResultPayload {
    /// Tool call ID this result corresponds to.
    pub tool_call_id: String,
    /// Result content.
    pub content: String,
    /// Whether the tool execution errored.
    pub is_error: bool,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Files affected by the tool.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affected_files: Option<Vec<String>>,
    /// Whether the content was truncated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    /// Blob ID for truncated content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_id: Option<String>,
}
