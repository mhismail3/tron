//! Claude Code JSONL record types.
//!
//! Each line in a Claude Code session file (`~/.claude/projects/<dir>/<uuid>.jsonl`)
//! deserializes to a [`ClaudeRecord`]. Fields are liberally `Option` to tolerate
//! variation across Claude Code versions.

use serde::Deserialize;
use serde_json::Value;

/// Top-level JSONL record from a Claude Code session file.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeRecord {
    /// Record type discriminator: "user", "assistant", "system", etc.
    #[serde(rename = "type")]
    pub record_type: String,

    /// Unique ID for this record (absent on some metadata record types).
    pub uuid: Option<String>,

    /// Parent record UUID (forms the conversation tree).
    pub parent_uuid: Option<String>,

    /// Session UUID (matches the JSONL filename).
    pub session_id: Option<String>,

    /// ISO-8601 timestamp.
    pub timestamp: Option<String>,

    /// The message payload (present on `user` and `assistant` records).
    pub message: Option<ClaudeMessage>,

    /// Groups user records in the same conversational turn.
    pub prompt_id: Option<String>,

    /// True for system-injected context records (CLAUDE.md, env info).
    pub is_meta: Option<bool>,

    /// True for compaction summary records.
    pub is_compact_summary: Option<bool>,

    /// Subtype for `system` records: `compact_boundary`, `api_error`, etc.
    pub subtype: Option<String>,

    /// Session display title (on `custom-title` records).
    pub custom_title: Option<String>,

    /// Human-readable session slug (on `assistant` records after first turn).
    pub slug: Option<String>,

    /// API request ID (on `assistant` records).
    pub request_id: Option<String>,

    /// Working directory at time of record.
    pub cwd: Option<String>,

    /// Claude Code version.
    pub version: Option<String>,

    /// Git branch at time of record.
    pub git_branch: Option<String>,

    /// Tool-use ID being responded to (on capability-result `user` records).
    pub source_tool_use_id: Option<String>,

    /// UUID of the assistant record that issued the capability invocation.
    #[serde(rename = "sourceToolAssistantUUID")]
    pub source_tool_assistant_uuid: Option<String>,

    /// Reference message ID (on `file-history-snapshot` records).
    pub message_id: Option<String>,

    /// Whether this is an update to an existing snapshot.
    pub is_snapshot_update: Option<bool>,

    /// Last user prompt text (on `last-prompt` records).
    pub last_prompt: Option<String>,

    /// True if this is an API error message (synthetic assistant records).
    pub is_api_error_message: Option<bool>,
}

/// The `message` field inside a [`ClaudeRecord`].
#[derive(Debug, Clone, Deserialize)]
pub struct ClaudeMessage {
    /// API message ID — shared across all chunked assistant records for one response.
    pub id: Option<String>,

    /// "user" or "assistant".
    pub role: Option<String>,

    /// Message content: a JSON string or an array of content blocks.
    pub content: Option<Value>,

    /// Model ID (e.g., "claude-opus-4-6").
    pub model: Option<String>,

    /// Stop reason: `end_turn`, `tool_use`, or null (for partial chunks).
    pub stop_reason: Option<String>,

    /// Token usage for this API call.
    pub usage: Option<ClaudeUsage>,
}

/// Token usage from Claude API response.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
#[allow(missing_docs)]
pub struct ClaudeUsage {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_input_tokens: i64,
    pub cache_creation_input_tokens: i64,
}

/// Recognized Claude Code record types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum RecordKind {
    User,
    Assistant,
    System,
    Progress,
    FileHistorySnapshot,
    Attachment,
    CustomTitle,
    AgentName,
    LastPrompt,
    QueueOperation,
    PermissionMode,
    Unknown,
}

impl RecordKind {
    /// Parse a record type string into a [`RecordKind`].
    pub fn parse(s: &str) -> Self {
        match s {
            "user" => Self::User,
            "assistant" => Self::Assistant,
            "system" => Self::System,
            "progress" => Self::Progress,
            "file-history-snapshot" => Self::FileHistorySnapshot,
            "attachment" => Self::Attachment,
            "custom-title" => Self::CustomTitle,
            "agent-name" => Self::AgentName,
            "last-prompt" => Self::LastPrompt,
            "queue-operation" => Self::QueueOperation,
            "permission-mode" => Self::PermissionMode,
            _ => Self::Unknown,
        }
    }
}

impl ClaudeRecord {
    /// Parse the record type string into a [`RecordKind`].
    pub fn kind(&self) -> RecordKind {
        RecordKind::parse(&self.record_type)
    }

    /// Whether this is a user record containing a capability result.
    pub fn is_tool_result(&self) -> bool {
        if self.kind() != RecordKind::User {
            return false;
        }
        let Some(msg) = &self.message else {
            return false;
        };
        let Some(content) = &msg.content else {
            return false;
        };
        // Content is an array with a tool_result block as first element
        content
            .as_array()
            .and_then(|arr| arr.first())
            .and_then(|block| block.get("type"))
            .and_then(Value::as_str)
            == Some("tool_result")
    }
}

#[cfg(test)]
#[path = "types_tests.rs"]
mod tests;
