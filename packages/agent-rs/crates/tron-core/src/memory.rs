//! Memory types for session context and handoff tracking.
//!
//! - [`SessionMemory`]: In-memory state for an active session
//! - [`HandoffRecord`]: Serialized context for session continuation

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::messages::{Message, ToolCall};

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
    /// If continuing from a handoff.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_handoff_id: Option<String>,
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
            parent_handoff_id: None,
            token_usage: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Handoff record
// ─────────────────────────────────────────────────────────────────────────────

/// Handoff record for session continuation.
///
/// When a session ends, a handoff captures enough context for a
/// successor session to continue the work.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandoffRecord {
    /// Unique handoff ID.
    pub id: String,
    /// Source session ID.
    pub session_id: String,
    /// ISO 8601 creation time.
    pub created_at: String,
    /// Summary of what was accomplished.
    pub summary: String,
    /// Remaining tasks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_tasks: Option<Vec<String>>,
    /// Arbitrary context.
    #[serde(default)]
    pub context: serde_json::Map<String, Value>,
    /// Number of messages in the source session.
    pub message_count: u32,
    /// Number of tool calls in the source session.
    pub tool_call_count: u32,
    /// Parent handoff if this is a chain.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_handoff_id: Option<String>,
    /// Compressed conversation for context injection.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compressed_messages: Option<String>,
    /// Key insights from the session.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key_insights: Option<Vec<String>>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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

    #[test]
    fn session_token_usage_default() {
        let usage = SessionTokenUsage::default();
        assert_eq!(usage.input, 0);
        assert_eq!(usage.output, 0);
    }

    #[test]
    fn handoff_record_serde_roundtrip() {
        let record = HandoffRecord {
            id: "h-1".into(),
            session_id: "sess-1".into(),
            created_at: "2026-01-15T12:00:00Z".into(),
            summary: "Implemented feature X".into(),
            pending_tasks: Some(vec!["Write tests".into()]),
            context: serde_json::Map::new(),
            message_count: 50,
            tool_call_count: 20,
            parent_handoff_id: None,
            compressed_messages: Some("User asked to build X. Agent created files...".into()),
            key_insights: Some(vec!["Uses vitest, not bun:test".into()]),
        };
        let json = serde_json::to_string(&record).unwrap();
        let back: HandoffRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(record, back);
    }

    #[test]
    fn handoff_record_minimal() {
        let json = json!({
            "id": "h-1",
            "sessionId": "sess-1",
            "createdAt": "2026-01-15T12:00:00Z",
            "summary": "Did stuff",
            "messageCount": 10,
            "toolCallCount": 5
        });
        let record: HandoffRecord = serde_json::from_value(json).unwrap();
        assert_eq!(record.id, "h-1");
        assert!(record.pending_tasks.is_none());
        assert!(record.key_insights.is_none());
    }

    #[test]
    fn handoff_record_with_parent() {
        let record = HandoffRecord {
            id: "h-2".into(),
            session_id: "sess-2".into(),
            created_at: "2026-01-15T13:00:00Z".into(),
            summary: "Continued from parent".into(),
            pending_tasks: None,
            context: serde_json::Map::new(),
            message_count: 20,
            tool_call_count: 8,
            parent_handoff_id: Some("h-1".into()),
            compressed_messages: None,
            key_insights: None,
        };
        let json = serde_json::to_value(&record).unwrap();
        assert_eq!(json["parentHandoffId"], "h-1");
    }
}
