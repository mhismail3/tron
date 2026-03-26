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
use crate::core::tools::{Tool, ToolCategory, TronToolResult};

use crate::tools::errors::ToolError;

// ─────────────────────────────────────────────────────────────────────────────
// Execution mode
// ─────────────────────────────────────────────────────────────────────────────

/// Controls how a tool is scheduled relative to other tools in the same batch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExecutionMode {
    /// Execute concurrently with all other parallel tools (default).
    Parallel,
    /// Execute sequentially within a named group. Tools in the same group
    /// run one-at-a-time in their original order. Different groups (and
    /// all Parallel tools) can execute concurrently.
    Serialized(String),
}

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
    /// Workspace ID for scoping memory recall (resolved from working directory).
    pub workspace_id: Option<String>,
    /// Channel for streaming tool output in real time (e.g., bash stdout chunks).
    /// Tools send String chunks; the runtime forwards them as `ToolExecutionUpdate` events.
    pub output_tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
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

    /// Controls parallel vs serialized scheduling in multi-tool batches.
    ///
    /// Override to return [`ExecutionMode::Serialized`] for tools that share
    /// session state (e.g. browser automation) and must not run concurrently.
    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Parallel
    }

    /// Generate the [`Tool`] schema for the LLM.
    fn definition(&self) -> Tool;

    /// Execute the tool with JSON arguments.
    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError>;
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
    /// Parent session ID (for event persistence to parent's linearized chain).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_session_id: Option<String>,
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
    /// Current nesting depth (set by `SubagentManager`, not user).
    #[serde(default)]
    pub current_depth: u32,
    /// Tool call ID that triggered the spawn (for iOS event correlation).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
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
    /// Data to pipe to the process's stdin (closed after write).
    pub stdin: Option<String>,
    /// Shell to use for command execution ("bash", "zsh", "sh").
    pub shell: String,
    /// Whether to run in PTY/interactive mode.
    pub interactive: bool,
    /// Pattern-response pairs for interactive mode.
    /// Each entry: (`wait_pattern`, `send_response`).
    pub pty_input: Vec<(String, String)>,
    /// Channel for streaming stdout chunks in real time.
    pub output_tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
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

/// Result from content summarization.
#[derive(Clone, Debug)]
pub struct SummarizerResult {
    /// The summarized answer.
    pub answer: String,
    /// Session ID of the subagent that produced the summary.
    pub session_id: String,
}

/// Content summarizer for `WebFetch` — sends fetched content to a Haiku
/// subagent and returns a concise answer to the user's question.
#[async_trait]
pub trait ContentSummarizer: Send + Sync {
    /// Summarize content by answering a task prompt via a subagent.
    async fn summarize(
        &self,
        task: &str,
        parent_session_id: &str,
    ) -> Result<SummarizerResult, ToolError>;
}

/// Subagent spawning (`SpawnSubagent`, `WaitForAgents`, `WebFetch` summarizer).
#[async_trait]
pub trait SubagentSpawner: Send + Sync {
    /// Spawn a new subagent.
    async fn spawn(&self, config: SubagentConfig) -> Result<SubagentHandle, ToolError>;
    /// Wait for one or more subagents to complete.
    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError>;
}

/// iOS app notifications (`NotifyApp`).
#[async_trait]
pub trait NotifyDelegate: Send + Sync {
    /// Send a push notification.
    async fn send_notification(
        &self,
        notification: &Notification,
    ) -> Result<NotifyResult, ToolError>;
}

/// Stores large content externally, returning a reference ID.
///
/// Used by `BashTool` to offload large outputs to blob storage instead of
/// sending them verbatim to the LLM. Content-addressable (deduplicates by hash).
#[async_trait]
pub trait BlobStore: Send + Sync {
    /// Store content, returns blob ID.
    async fn store(
        &self,
        content: &[u8],
        mime_type: &str,
    ) -> Result<String, crate::tools::errors::ToolError>;
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
    /// Response headers (populated in raw/request mode).
    pub headers: HashMap<String, String>,
}

/// HTTP request configuration for the universal `request()` method.
pub struct HttpRequest<'a> {
    /// Target URL.
    pub url: &'a str,
    /// HTTP method (GET, POST, PUT, PATCH, DELETE, HEAD).
    pub method: &'a str,
    /// Request headers.
    pub headers: Vec<(&'a str, &'a str)>,
    /// Request body (raw string).
    pub body: Option<&'a str>,
    /// Whether to follow redirects.
    pub follow_redirects: bool,
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

    /// Perform a full HTTP request with method, headers, body, and redirect control.
    async fn request(&self, req: &HttpRequest<'_>) -> Result<HttpResponse, ToolError>;
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
            workspace_id: None,
            output_tx: None,
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
            workspace_id: None,
            output_tx: None,
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
            workspace_id: None,
            output_tx: None,
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
    fn execution_mode_default_is_parallel() {
        // Verify that the default ExecutionMode is Parallel
        assert_eq!(ExecutionMode::Parallel, ExecutionMode::Parallel);
        assert_ne!(
            ExecutionMode::Parallel,
            ExecutionMode::Serialized("browser".into())
        );
    }

    #[test]
    fn execution_mode_serialized_equality() {
        assert_eq!(
            ExecutionMode::Serialized("browser".into()),
            ExecutionMode::Serialized("browser".into())
        );
        assert_ne!(
            ExecutionMode::Serialized("browser".into()),
            ExecutionMode::Serialized("shell".into())
        );
    }

    #[test]
    fn process_options_default_construction() {
        let opts = ProcessOptions {
            working_directory: "/tmp".into(),
            timeout_ms: 120_000,
            cancellation: CancellationToken::new(),
            env: HashMap::new(),
            stdin: None,
            shell: "bash".into(),
            interactive: false,
            pty_input: Vec::new(),
            output_tx: None,
        };
        assert_eq!(opts.timeout_ms, 120_000);
        assert!(opts.env.is_empty());
        assert!(opts.stdin.is_none());
        assert_eq!(opts.shell, "bash");
        assert!(!opts.interactive);
        assert!(opts.pty_input.is_empty());
    }
}
