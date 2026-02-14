//! Database row types for mapping between `SQLite` rows and Rust structs.
//!
//! These represent the raw database row shape — not the public API types.
//! Conversion to public types (e.g., [`Workspace`], [`SessionSummary`])
//! happens in the repository layer.

use serde::{Deserialize, Serialize};

/// Raw session row from the `sessions` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionRow {
    /// Session ID.
    pub id: String,
    /// Workspace ID.
    pub workspace_id: String,
    /// Head event ID.
    pub head_event_id: Option<String>,
    /// Root event ID.
    pub root_event_id: Option<String>,
    /// Session title.
    pub title: Option<String>,
    /// Latest model ID.
    pub latest_model: String,
    /// Working directory.
    pub working_directory: String,
    /// Parent session ID (for forks).
    pub parent_session_id: Option<String>,
    /// Fork point event ID.
    pub fork_from_event_id: Option<String>,
    /// Creation timestamp.
    pub created_at: String,
    /// Last activity timestamp.
    pub last_activity_at: String,
    /// End timestamp (null if active).
    pub ended_at: Option<String>,
    /// Event count.
    pub event_count: i64,
    /// Message count.
    pub message_count: i64,
    /// Turn count.
    pub turn_count: i64,
    /// Total input tokens.
    pub total_input_tokens: i64,
    /// Total output tokens.
    pub total_output_tokens: i64,
    /// Last turn input tokens.
    pub last_turn_input_tokens: i64,
    /// Total cost in USD.
    pub total_cost: f64,
    /// Total cache read tokens.
    pub total_cache_read_tokens: i64,
    /// Total cache creation tokens.
    pub total_cache_creation_tokens: i64,
    /// Tags as JSON array string.
    pub tags: String,
    /// Spawning session ID (for subagents).
    pub spawning_session_id: Option<String>,
    /// Spawn type.
    pub spawn_type: Option<String>,
    /// Spawn task description.
    pub spawn_task: Option<String>,
}

/// Raw event row from the `events` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EventRow {
    /// Event ID.
    pub id: String,
    /// Session ID.
    pub session_id: String,
    /// Parent event ID.
    pub parent_id: Option<String>,
    /// Sequence number.
    pub sequence: i64,
    /// Depth in event tree.
    pub depth: i64,
    /// Event type string.
    #[serde(rename = "type")]
    pub event_type: String,
    /// Timestamp.
    pub timestamp: String,
    /// Payload JSON.
    pub payload: String,
    /// Content blob ID.
    pub content_blob_id: Option<String>,
    /// Workspace ID.
    pub workspace_id: String,
    /// Denormalized role.
    pub role: Option<String>,
    /// Denormalized tool name.
    pub tool_name: Option<String>,
    /// Denormalized tool call ID.
    pub tool_call_id: Option<String>,
    /// Denormalized turn number.
    pub turn: Option<i64>,
    /// Denormalized input tokens.
    pub input_tokens: Option<i64>,
    /// Denormalized output tokens.
    pub output_tokens: Option<i64>,
    /// Denormalized cache read tokens.
    pub cache_read_tokens: Option<i64>,
    /// Denormalized cache creation tokens.
    pub cache_creation_tokens: Option<i64>,
    /// Checksum.
    pub checksum: Option<String>,
}

/// Raw workspace row from the `workspaces` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceRow {
    /// Workspace ID.
    pub id: String,
    /// Absolute path.
    pub path: String,
    /// Display name.
    pub name: Option<String>,
    /// Creation timestamp.
    pub created_at: String,
    /// Last activity timestamp.
    pub last_activity_at: String,
    /// Session count (computed via subquery).
    pub session_count: Option<i64>,
}

/// Raw branch row from the `branches` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BranchRow {
    /// Branch ID.
    pub id: String,
    /// Session ID.
    pub session_id: String,
    /// Branch name.
    pub name: String,
    /// Description.
    pub description: Option<String>,
    /// Root event ID.
    pub root_event_id: String,
    /// Head event ID.
    pub head_event_id: String,
    /// Whether this is the default branch.
    pub is_default: bool,
    /// Creation timestamp.
    pub created_at: String,
    /// Last activity timestamp.
    pub last_activity_at: String,
}

/// Raw device token row from the `device_tokens` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceTokenRow {
    /// Device token registration ID.
    pub id: String,
    /// APNS device token (64-char hex).
    pub device_token: String,
    /// Associated session ID.
    pub session_id: Option<String>,
    /// Associated workspace ID.
    pub workspace_id: Option<String>,
    /// Platform (always "ios" for now).
    pub platform: String,
    /// APNS environment ("sandbox" or "production").
    pub environment: String,
    /// Creation timestamp.
    pub created_at: String,
    /// Last used timestamp.
    pub last_used_at: String,
    /// Whether the token is active.
    pub is_active: bool,
}

/// Raw blob row from the `blobs` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlobRow {
    /// Blob ID.
    pub id: String,
    /// Content hash (SHA-256).
    pub hash: String,
    /// Blob content.
    pub content: Vec<u8>,
    /// MIME type.
    pub mime_type: String,
    /// Original content size.
    pub size_original: i64,
    /// Compressed content size.
    pub size_compressed: i64,
    /// Compression algorithm.
    pub compression: String,
    /// Creation timestamp.
    pub created_at: String,
    /// Reference count.
    pub ref_count: i64,
}
