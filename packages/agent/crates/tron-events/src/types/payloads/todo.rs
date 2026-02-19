//! Todo event payloads.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `todo.write` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoWritePayload {
    /// Todo items.
    pub todos: Vec<TodoItem>,
    /// What triggered the write.
    pub trigger: String,
}

/// A single todo item.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TodoItem {
    /// Item ID.
    pub id: String,
    /// Item content/description.
    pub content: String,
    /// Active form text (shown in UI spinner).
    pub active_form: String,
    /// Status: "pending", "in\_progress", "completed".
    pub status: String,
    /// Source: "agent", "user", "skill".
    pub source: String,
    /// Creation timestamp.
    pub created_at: String,
    /// Completion timestamp.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Arbitrary metadata.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
}
