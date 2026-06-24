//! SQLite row types for the primitive session store.

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
    /// Parent session ID for forks.
    pub parent_session_id: Option<String>,
    /// Event ID used as the fork point.
    pub fork_from_event_id: Option<String>,
    /// Creation timestamp.
    pub created_at: String,
    /// Last activity timestamp.
    pub last_activity_at: String,
    /// End timestamp, when archived or completed.
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
    /// Total model cost.
    pub total_cost: f64,
    /// Total cache read tokens.
    pub total_cache_read_tokens: i64,
    /// Total cache creation tokens.
    pub total_cache_creation_tokens: i64,
    /// Tags as a JSON array string.
    pub tags: String,
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
    /// Denormalized model primitive name.
    pub model_primitive_name: Option<String>,
    /// Denormalized invocation ID.
    pub invocation_id: Option<String>,
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
    /// Payload checksum.
    pub checksum: Option<String>,
    /// Model ID.
    pub model: Option<String>,
    /// Turn duration in milliseconds.
    pub latency_ms: Option<i64>,
    /// Model stop reason.
    pub stop_reason: Option<String>,
    /// Whether the response contained thinking blocks.
    pub has_thinking: Option<i64>,
    /// Provider type.
    pub provider_type: Option<String>,
    /// Estimated cost.
    pub cost: Option<f64>,
}

impl EventRow {
    /// Create a sentinel row used only for flush synchronization.
    pub fn flush_sentinel() -> Self {
        Self {
            id: String::new(),
            session_id: String::new(),
            parent_id: None,
            sequence: 0,
            depth: 0,
            event_type: String::new(),
            timestamp: String::new(),
            payload: String::new(),
            content_blob_id: None,
            workspace_id: String::new(),
            role: None,
            model_primitive_name: None,
            invocation_id: None,
            turn: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_creation_tokens: None,
            checksum: None,
            model: None,
            latency_ms: None,
            stop_reason: None,
            has_thinking: None,
            provider_type: None,
            cost: None,
        }
    }
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
    /// Session count from listing queries.
    pub session_count: Option<i64>,
}

/// Raw blob row from the `blobs` table.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BlobRow {
    /// Blob ID.
    pub id: String,
    /// Content hash.
    pub hash: String,
    /// Blob content.
    pub content: Vec<u8>,
    /// MIME type.
    pub mime_type: String,
    /// Uncompressed content size.
    pub uncompressed_size: i64,
    /// Compressed content size.
    pub size_compressed: i64,
    /// Compression algorithm.
    pub compression: String,
    /// Creation timestamp.
    pub created_at: String,
    /// Reference count.
    pub ref_count: i64,
}
