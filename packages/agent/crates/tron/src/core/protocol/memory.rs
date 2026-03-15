//! Memory types for active session context.
//!
//! - [`SessionMemory`]: In-memory state for an active session

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::messages::{Message, ToolCall};

// ─────────────────────────────────────────────────────────────────────────────
// Session memory
// ─────────────────────────────────────────────────────────────────────────────

/// Token usage summary for a session.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionTokenUsage {
    /// Total input tokens.
    pub input: u64,
    /// Total output tokens.
    pub output: u64,
}

/// Active session memory — in-memory state during a conversation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMemory {
    /// Session ID.
    pub session_id: String,
    /// ISO 8601 start time.
    pub started_at: String,
    /// ISO 8601 end time (set when session closes).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<String>,
    /// Conversation messages.
    pub messages: Vec<Message>,
    /// Tool calls made during the session.
    pub tool_calls: Vec<ToolCall>,
    /// Working directory path.
    pub working_directory: String,
    /// Files the agent is currently working with.
    pub active_files: Vec<String>,
    /// Arbitrary session context.
    #[serde(default)]
    pub context: serde_json::Map<String, Value>,
    /// Token usage for this session.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<SessionTokenUsage>,
}

impl SessionMemory {
    /// Create a new session memory for the given session.
    #[must_use]
    pub fn new(session_id: impl Into<String>, working_directory: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            started_at: chrono::Utc::now().to_rfc3339(),
            ended_at: None,
            messages: Vec::new(),
            tool_calls: Vec::new(),
            working_directory: working_directory.into(),
            active_files: Vec::new(),
            context: serde_json::Map::new(),
            token_usage: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_memory_new() {
        let mem = SessionMemory::new("sess-1", "/tmp/project");
        assert_eq!(mem.session_id, "sess-1");
        assert_eq!(mem.working_directory, "/tmp/project");
        assert!(mem.messages.is_empty());
        assert!(mem.tool_calls.is_empty());
        assert!(mem.ended_at.is_none());
        assert!(!mem.started_at.is_empty());
    }

    #[test]
    fn session_memory_serde_roundtrip() {
        let mem = SessionMemory::new("sess-1", "/tmp");
        let json = serde_json::to_string(&mem).unwrap();
        let back: SessionMemory = serde_json::from_str(&json).unwrap();
        assert_eq!(mem, back);
    }

    #[test]
    fn session_memory_with_token_usage() {
        let mut mem = SessionMemory::new("sess-1", "/tmp");
        mem.token_usage = Some(SessionTokenUsage {
            input: 5000,
            output: 2000,
        });
        let json = serde_json::to_value(&mem).unwrap();
        assert_eq!(json["tokenUsage"]["input"], 5000);
        assert_eq!(json["tokenUsage"]["output"], 2000);
    }
}
