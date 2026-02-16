//! Core trait and DI abstractions for the tool system.
//!
//! Defines [`TronTool`] — the trait every tool implements — plus all dependency
//! injection traits that tools use to interact with external services. The runtime
//! (Phase 8) provides concrete implementations of these traits.

use std::collections::HashMap;
use std::io;
use std::path::Path;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;
use tron_core::tools::{Tool, ToolCategory, TronToolResult};

use crate::errors::ToolError;

// ─────────────────────────────────────────────────────────────────────────────
// Tool context
// ─────────────────────────────────────────────────────────────────────────────

/// Execution context passed to every tool invocation.
#[derive(Clone, Debug)]
pub struct ToolContext {
    /// Unique ID of this tool call.
    pub tool_call_id: String,
    /// Session ID of the agent invoking this tool.
    pub session_id: String,
    /// Working directory for path resolution.
    pub working_directory: String,
    /// Cancellation token for cooperative cancellation.
    pub cancellation: CancellationToken,
    /// Current subagent nesting depth (0 = root agent).
    pub subagent_depth: u32,
    /// Maximum nesting depth allowed for spawning children.
    pub subagent_max_depth: u32,
}

// ─────────────────────────────────────────────────────────────────────────────
// TronTool trait
// ─────────────────────────────────────────────────────────────────────────────

/// The core trait that every tool must implement.
///
/// Each tool provides:
/// - **Schema** via [`definition()`](TronTool::definition) — sent to the LLM
/// - **Execution** via [`execute()`](TronTool::execute) — invoked with JSON params
/// - **Metadata** — name, category, interactivity, stop-turn behavior
#[async_trait]
pub trait TronTool: Send + Sync {
    /// Tool name — the exact string sent to/from the LLM.
    fn name(&self) -> &str;

    /// Tool category for grouping.
    fn category(&self) -> ToolCategory;

    /// Whether this tool requires user interaction (excluded from subagents).
    fn is_interactive(&self) -> bool {
        false
    }

    /// Whether execution stops the agent turn loop.
    fn stops_turn(&self) -> bool {
        false
    }

    /// Optional per-tool timeout in milliseconds.
    fn timeout_ms(&self) -> Option<u64> {
        None
    }

    /// Generate the [`Tool`] schema for the LLM.
    fn definition(&self) -> Tool;

    /// Execute the tool with JSON arguments.
    async fn execute(
        &self,
        params: Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Subagent types
// ─────────────────────────────────────────────────────────────────────────────

/// Configuration for spawning a subagent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentConfig {
    /// Task description for the subagent.
    pub task: String,
    /// Execution mode.
    pub mode: SubagentMode,
    /// Whether to block until the subagent completes.
    pub blocking: bool,
    /// Optional model override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// Optional system prompt.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// Working directory for the subagent.
    pub working_directory: String,
    /// Maximum turns before stopping.
    pub max_turns: u32,
    /// Timeout in milliseconds.
    pub timeout_ms: u64,
    /// Tool denials configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_denials: Option<Value>,
    /// Skills to enable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skills: Option<Vec<String>>,
    /// Maximum nesting depth (0 = no children, 1 = one level, etc.).
    #[serde(default)]
    pub max_depth: u32,
    /// Current nesting depth (set by SubagentManager, not user).
    #[serde(default)]
    pub current_depth: u32,
}

/// Subagent execution mode.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SubagentMode {
    /// Run in the same process.
    InProcess,
    /// Run in a tmux session.
    Tmux,
}

/// Handle to a running or completed subagent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentHandle {
    /// Session ID of the subagent.
    pub session_id: String,
    /// Output (only present if blocking).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Token usage (only present if blocking).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<Value>,
}

/// Wait mode for `WaitForAgents`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WaitMode {
    /// Wait for all agents to complete.
    All,
    /// Wait for any one agent to complete.
    Any,
}

/// Result from a completed subagent.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubagentResult {
    /// Session ID.
    pub session_id: String,
    /// Output text.
    pub output: String,
    /// Token usage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<Value>,
    /// Duration in milliseconds.
    pub duration_ms: u64,
    /// Completion status.
    pub status: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Browser types
// ─────────────────────────────────────────────────────────────────────────────

/// A browser automation action.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserAction {
    /// Action name (navigate, click, snapshot, etc.).
    pub action: String,
    /// Action-specific parameters.
    #[serde(flatten)]
    pub params: Value,
}

/// Result from a browser action.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserResult {
    /// Output content.
    pub content: String,
    /// Optional details.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Notification types
// ─────────────────────────────────────────────────────────────────────────────

/// A notification to send to the iOS app.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    /// Notification title.
    pub title: String,
    /// Notification body.
    pub body: String,
    /// Priority level.
    #[serde(default = "default_priority")]
    pub priority: String,
    /// Optional badge count.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub badge: Option<u32>,
    /// Optional custom data payload.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    /// Optional sheet content (metadata only, not in push).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sheet_content: Option<Value>,
}

fn default_priority() -> String {
    "normal".into()
}

/// Result from sending a notification.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NotifyResult {
    /// Whether the notification was sent successfully.
    pub success: bool,
    /// Diagnostic message (device count, errors).
    #[serde(default)]
    pub message: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Message bus types
// ─────────────────────────────────────────────────────────────────────────────

/// An outgoing inter-session message.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutgoingMessage {
    /// Target session ID.
    pub target_session_id: String,
    /// Message type.
    pub message_type: String,
    /// Message payload.
    pub payload: Value,
    /// Whether to wait for a reply.
    pub wait_for_reply: bool,
    /// Timeout in milliseconds for reply wait.
    pub timeout_ms: u64,
}

/// Result from sending a message.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageSendResult {
    /// Message ID.
    pub message_id: String,
    /// Reply (only if `wait_for_reply` was true).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply: Option<Value>,
}

/// Filter for receiving messages.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MessageFilter {
    /// Filter by message type.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message_type: Option<String>,
    /// Filter by sender session ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from_session_id: Option<String>,
    /// Whether to mark messages as read.
    #[serde(default = "default_true")]
    pub mark_as_read: bool,
    /// Maximum messages to return.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
}

fn default_true() -> bool {
    true
}

/// A received message.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReceivedMessage {
    /// Message ID.
    pub message_id: String,
    /// Sender session ID.
    pub from_session_id: String,
    /// Message type.
    pub message_type: String,
    /// Message payload.
    pub payload: Value,
    /// Timestamp.
    pub timestamp: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Memory types
// ─────────────────────────────────────────────────────────────────────────────

/// A memory entry from the event store.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEntry {
    /// Entry content.
    pub content: String,
    /// Source session ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Relevance score (0–100).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub score: Option<u32>,
    /// Timestamp.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamp: Option<String>,
}

/// Session info from the event store.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    /// Session ID.
    pub session_id: String,
    /// Session title.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Created timestamp.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    /// Whether the session is archived.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub archived: Option<bool>,
    /// Event count.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_count: Option<u64>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Process types
// ─────────────────────────────────────────────────────────────────────────────

/// Options for spawning a subprocess.
#[derive(Clone, Debug)]
pub struct ProcessOptions {
    /// Working directory.
    pub working_directory: String,
    /// Timeout in milliseconds.
    pub timeout_ms: u64,
    /// Cancellation token.
    pub cancellation: CancellationToken,
    /// Additional environment variables.
    pub env: HashMap<String, String>,
}

/// Output from a subprocess.
#[derive(Clone, Debug)]
pub struct ProcessOutput {
    /// Standard output.
    pub stdout: String,
    /// Standard error.
    pub stderr: String,
    /// Exit code.
    pub exit_code: i32,
    /// Duration in milliseconds.
    pub duration_ms: u64,
    /// Whether the process timed out.
    pub timed_out: bool,
    /// Whether the process was interrupted.
    pub interrupted: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Dependency injection traits
// ─────────────────────────────────────────────────────────────────────────────

/// Filesystem operations (Read, Write, Edit, Find).
#[async_trait]
pub trait FileSystemOps: Send + Sync {
    /// Read the contents of a file.
    async fn read_file(&self, path: &Path) -> Result<Vec<u8>, io::Error>;
    /// Write content to a file.
    async fn write_file(&self, path: &Path, content: &[u8]) -> Result<(), io::Error>;
    /// Get file metadata.
    async fn metadata(&self, path: &Path) -> Result<std::fs::Metadata, io::Error>;
    /// Create a directory and all parent directories.
    async fn create_dir_all(&self, path: &Path) -> Result<(), io::Error>;
    /// Check if a path exists.
    fn exists(&self, path: &Path) -> bool;
}

/// Subprocess execution (Bash, Search AST mode).
#[async_trait]
pub trait ProcessRunner: Send + Sync {
    /// Run a shell command.
    async fn run_command(
        &self,
        command: &str,
        opts: &ProcessOptions,
    ) -> Result<ProcessOutput, ToolError>;
}

/// Subagent spawning (`SpawnSubagent`, `WebFetch` summarizer).
#[async_trait]
pub trait SubagentSpawner: Send + Sync {
    /// Spawn a new subagent.
    async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError>;
    /// Query a subagent.
    async fn query_agent(
        &self,
        session_id: &str,
        query_type: &str,
        limit: Option<u32>,
    ) -> Result<Value, ToolError>;
    /// Wait for one or more subagents to complete.
    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError>;
}

/// Browser automation (`BrowseTheWeb`).
#[async_trait]
pub trait BrowserDelegate: Send + Sync {
    /// Execute a browser action.
    async fn execute_action(
        &self,
        session_id: &str,
        action: &BrowserAction,
    ) -> Result<BrowserResult, ToolError>;
    /// Close a browser session.
    async fn close_session(&self, session_id: &str) -> Result<(), ToolError>;
}

/// iOS app notifications (`NotifyApp`, `OpenURL`).
#[async_trait]
pub trait NotifyDelegate: Send + Sync {
    /// Send a push notification.
    async fn send_notification(
        &self,
        notification: &Notification,
    ) -> Result<NotifyResult, ToolError>;
    /// Open a URL in the app.
    async fn open_url_in_app(&self, url: &str) -> Result<(), ToolError>;
}

/// Inter-session message bus (`send_message`, `receive_messages`).
#[async_trait]
pub trait MessageBus: Send + Sync {
    /// Send a message to another session.
    async fn send_message(&self, msg: &OutgoingMessage) -> Result<MessageSendResult, ToolError>;
    /// Receive messages for a session.
    async fn receive_messages(
        &self,
        session_id: &str,
        filter: &MessageFilter,
    ) -> Result<Vec<ReceivedMessage>, ToolError>;
}

/// Event store queries (`Remember` tool).
#[async_trait]
pub trait EventStoreQuery: Send + Sync {
    /// Semantic memory recall.
    async fn recall_memory(
        &self,
        query: &str,
        limit: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError>;
    /// Full-text search.
    async fn search_memory(
        &self,
        session_id: Option<&str>,
        query: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError>;
    /// List sessions.
    async fn list_sessions(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<SessionInfo>, ToolError>;
    /// Get a single session.
    async fn get_session(&self, session_id: &str) -> Result<Option<SessionInfo>, ToolError>;
    /// Get events for a session.
    async fn get_events(
        &self,
        session_id: &str,
        event_type: Option<&str>,
        turn: Option<u32>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Value>, ToolError>;
    /// Get conversation messages.
    async fn get_messages(&self, session_id: &str, limit: u32) -> Result<Vec<Value>, ToolError>;
    /// Get tool calls.
    async fn get_tool_calls(&self, session_id: &str, limit: u32) -> Result<Vec<Value>, ToolError>;
    /// Get application logs.
    async fn get_logs(
        &self,
        session_id: &str,
        level: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Value>, ToolError>;
    /// Get database statistics.
    async fn get_stats(&self) -> Result<Value, ToolError>;
    /// Get database schema.
    async fn get_schema(&self) -> Result<String, ToolError>;
    /// Read a blob by ID.
    async fn read_blob(&self, blob_id: &str) -> Result<String, ToolError>;
}

/// Task management (`TaskManager` tool).
#[async_trait]
pub trait TaskManagerDelegate: Send + Sync {
    /// Execute a task management action.
    async fn execute_action(&self, action: &str, params: Value) -> Result<Value, ToolError>;
}

// ─────────────────────────────────────────────────────────────────────────────
// HTTP client
// ─────────────────────────────────────────────────────────────────────────────

/// HTTP response from a fetch operation.
pub struct HttpResponse {
    /// HTTP status code.
    pub status: u16,
    /// Response body as text.
    pub body: String,
    /// Content-Type header value.
    pub content_type: Option<String>,
}

/// HTTP client for web operations (`WebFetch`, `WebSearch`).
#[async_trait]
pub trait HttpClient: Send + Sync {
    /// Perform a GET request and return the response.
    async fn get(&self, url: &str) -> Result<HttpResponse, ToolError>;

    /// Perform a GET request with custom headers.
    ///
    /// Default implementation ignores headers and falls back to `get()`.
    async fn get_with_headers(
        &self,
        url: &str,
        headers: &[(&str, &str)],
    ) -> Result<HttpResponse, ToolError> {
        let _ = headers;
        self.get(url).await
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_context_construction() {
        let ctx = ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
        };
        assert_eq!(ctx.tool_call_id, "call-1");
        assert_eq!(ctx.session_id, "sess-1");
        assert_eq!(ctx.working_directory, "/tmp");
    }

    #[test]
    fn tool_context_default_depth_zero() {
        let ctx = ToolContext {
            tool_call_id: String::new(),
            session_id: String::new(),
            working_directory: String::new(),
            cancellation: CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
        };
        assert_eq!(ctx.subagent_depth, 0);
        assert_eq!(ctx.subagent_max_depth, 0);
    }

    #[test]
    fn tool_context_custom_depth() {
        let ctx = ToolContext {
            tool_call_id: String::new(),
            session_id: String::new(),
            working_directory: String::new(),
            cancellation: CancellationToken::new(),
            subagent_depth: 2,
            subagent_max_depth: 5,
        };
        assert_eq!(ctx.subagent_depth, 2);
        assert_eq!(ctx.subagent_max_depth, 5);
    }

    #[test]
    fn tool_category_serde_roundtrip() {
        for category in [
            ToolCategory::Filesystem,
            ToolCategory::Shell,
            ToolCategory::Search,
            ToolCategory::Network,
            ToolCategory::Custom,
        ] {
            let json = serde_json::to_string(&category).unwrap();
            let back: ToolCategory = serde_json::from_str(&json).unwrap();
            assert_eq!(category, back);
        }
    }

    #[test]
    fn wait_mode_serde_roundtrip() {
        for mode in [WaitMode::All, WaitMode::Any] {
            let json = serde_json::to_string(&mode).unwrap();
            let back: WaitMode = serde_json::from_str(&json).unwrap();
            assert_eq!(mode, back);
        }
    }

    #[test]
    fn subagent_mode_serde_roundtrip() {
        for mode in [SubagentMode::InProcess, SubagentMode::Tmux] {
            let json = serde_json::to_string(&mode).unwrap();
            let back: SubagentMode = serde_json::from_str(&json).unwrap();
            assert_eq!(mode, back);
        }
    }

    #[test]
    fn process_options_default_construction() {
        let opts = ProcessOptions {
            working_directory: "/tmp".into(),
            timeout_ms: 120_000,
            cancellation: CancellationToken::new(),
            env: HashMap::new(),
        };
        assert_eq!(opts.timeout_ms, 120_000);
        assert!(opts.env.is_empty());
    }
}
