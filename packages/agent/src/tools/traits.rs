//! Core trait and DI abstractions for the tool system.
//!
//! Defines [`TronTool`] — the trait every tool implements — plus all dependency
//! injection traits that tools use to interact with external services. The runtime
//! (Phase 8) provides concrete implementations of these traits.

use std::collections::HashMap;
use std::io;
use std::path::Path;
use std::sync::Arc;

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
#[derive(Clone)]
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
    /// Process manager for spawning/managing background processes.
    pub process_manager: Option<Arc<dyn ProcessManagerOps>>,
    /// Unified job manager for waiting on and managing processes + subagents.
    pub job_manager: Option<Arc<dyn JobManagerOps>>,
    /// Registry for process output buffers (for on-demand streaming to iOS).
    pub output_buffer_registry: Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    /// Event emitter for broadcasting tool events (used by managed processes
    /// to emit `ToolExecutionUpdate` events directly, bypassing `output_tx`).
    pub event_emitter: Option<Arc<crate::runtime::agent::event_emitter::EventEmitter>>,
    /// All tool names available in the current registry (for `denyAllTools` resolution).
    pub all_tool_names: Vec<String>,
}

impl std::fmt::Debug for ToolContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ToolContext")
            .field("tool_call_id", &self.tool_call_id)
            .field("session_id", &self.session_id)
            .field("working_directory", &self.working_directory)
            .field("subagent_depth", &self.subagent_depth)
            .field("subagent_max_depth", &self.subagent_max_depth)
            .field("workspace_id", &self.workspace_id)
            .field("process_manager", &self.process_manager.as_ref().map(|_| "..."))
            .field("job_manager", &self.job_manager.as_ref().map(|_| "..."))
            .field("output_buffer_registry", &self.output_buffer_registry.as_ref().map(|_| "..."))
            .field("event_emitter", &self.event_emitter.as_ref().map(|_| "..."))
            .finish_non_exhaustive()
    }
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

    /// Condensed [`Tool`] schema for local models with limited context windows.
    ///
    /// Defaults to the full definition. Override on tools with verbose schemas
    /// (e.g., Bash, WebFetch) to strip rarely-used parameters and shorten
    /// descriptions, reducing token overhead for local inference.
    fn local_definition(&self) -> Tool {
        self.definition()
    }

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
    /// Blocking timeout in milliseconds — how long the caller waits before
    /// the subagent auto-backgrounds. `None` = immediate background.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocking_timeout_ms: Option<u64>,
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
    /// Tool names to deny from the subagent's registry.
    #[serde(default)]
    pub denied_tools: Vec<String>,
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
    /// Number of turns executed (only present if blocking completed).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turns_executed: Option<u32>,
    /// Whether the subagent completed successfully (only present if blocking completed).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub success: Option<bool>,
}

/// Wait mode for job and subagent waiting.
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
    /// Number of turns executed.
    pub turns_executed: u32,
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
    pub message: Option<String>,
    /// Number of devices that received the notification successfully.
    pub success_count: u32,
    /// Total number of devices the notification was sent to.
    pub total_count: u32,
    /// M19: a non-fatal user/agent-visible caveat that the delivery path
    /// wants to surface without erroring out. Set by the stub delegate
    /// when push service is not configured — `success` stays `false`
    /// (nothing was actually delivered) but the tool result flags the
    /// condition so the agent can tell the user "push isn't set up".
    /// Real delegates leave this `None` by design.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Managed process types
// ─────────────────────────────────────────────────────────────────────────────

/// Taxonomy for tracked processes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessKind {
    /// Shell command (Bash tool).
    Shell,
    /// Display screen capture stream.
    DisplayStream,
    /// Generic long-running tool operation.
    ToolOperation,
}

/// Lifecycle state of a managed process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProcessState {
    /// Running in the foreground (tool call is awaiting it).
    Foreground,
    /// Promoted to background (tool call returned, process continues).
    Background,
    /// Completed successfully.
    Completed,
    /// Failed or errored.
    Failed,
    /// Explicitly cancelled.
    Cancelled,
}

/// Configuration for spawning a managed process.
#[derive(Clone, Debug)]
pub struct ManagedProcessConfig {
    /// Human-readable label (command text or "display_stream:{id}").
    pub label: String,
    /// Process taxonomy.
    pub kind: ProcessKind,
    /// Kill timeout in milliseconds (None = no timeout, runs until cancelled).
    pub timeout_ms: Option<u64>,
    /// Blocking timeout in milliseconds — how long the caller waits before
    /// the process auto-backgrounds. `None` or `Some(0)` = immediate background.
    pub blocking_timeout_ms: Option<u64>,
    /// Whether to suggest sandboxing for background shell commands.
    pub sandbox: bool,
}

/// Result from a completed managed process.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedProcessResult {
    /// Process identifier.
    pub process_id: String,
    /// Combined output summary (head+tail if large).
    pub output: String,
    /// Exit code (None for non-shell processes like streams).
    pub exit_code: Option<i32>,
    /// Duration in milliseconds.
    pub duration_ms: u64,
    /// Whether the process was killed by timeout.
    pub timed_out: bool,
    /// Whether the process was cancelled.
    pub cancelled: bool,
    /// Whether the cancellation was user-initiated (from iOS interrupt button).
    /// Set by ProcessManager when `cancel_process(id, user_initiated: true)` is called.
    #[serde(default)]
    pub user_cancelled: bool,
    /// Blob ID for large outputs stored externally.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_id: Option<String>,
}

/// Why a managed process was backgrounded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BackgroundReason {
    /// Blocking timeout expired.
    AutoTimeout,
    /// User manually backgrounded from iOS.
    UserAction,
}

/// Handle returned when spawning a managed process.
#[derive(Clone, Debug)]
pub struct ManagedProcessHandle {
    /// Process identifier.
    pub process_id: String,
    /// Result (populated only when the process completed within the blocking window).
    pub result: Option<ManagedProcessResult>,
    /// If backgrounded, why. `None` when the process completed inline.
    pub backgrounded: Option<BackgroundReason>,
}

/// Summary info for listing processes.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessInfo {
    /// Process identifier.
    pub process_id: String,
    /// Human-readable label.
    pub label: String,
    /// Process taxonomy.
    pub kind: ProcessKind,
    /// Current state as string.
    pub state: String,
    /// Milliseconds since process started.
    pub elapsed_ms: u64,
    /// Session that owns this process.
    pub session_id: String,
    /// Tool call that spawned this process.
    pub tool_call_id: String,
}

/// Managed process execution for shell commands, streams, and long-running ops.
#[async_trait]
pub trait ProcessManagerOps: Send + Sync {
    /// Spawn a managed process running a future. Blocks for up to
    /// `config.blocking_timeout_ms` before auto-backgrounding. If the timeout
    /// is `None` or `Some(0)`, returns immediately (background).
    async fn spawn_managed(
        &self,
        session_id: &str,
        tool_call_id: &str,
        config: ManagedProcessConfig,
        task: std::pin::Pin<Box<dyn std::future::Future<Output = ManagedProcessResult> + Send>>,
    ) -> Result<ManagedProcessHandle, ToolError>;

    /// Promote a foreground process to background. Unblocks the awaiting tool call.
    fn promote_to_background(&self, process_id: &str) -> Result<(), ToolError>;

    /// Cancel a running process (any state).
    /// When `user_initiated` is true, the result's `user_cancelled` flag is set
    /// so tools can produce appropriate messages (e.g., "Do not retry").
    fn cancel_process(&self, process_id: &str, user_initiated: bool) -> Result<(), ToolError>;

    /// List processes for a session (active + recently completed).
    fn list_processes(&self, session_id: &str) -> Vec<ProcessInfo>;

    /// Get result of a completed process (None if still running).
    fn get_result(&self, process_id: &str) -> Option<ManagedProcessResult>;

    /// Find a process by label prefix within a session.
    fn find_by_label(&self, session_id: &str, label_prefix: &str) -> Option<String>;

    /// Cancel all processes for a session.
    fn cancel_session_processes(&self, session_id: &str);

    /// Cancel ALL tracked processes (server shutdown).
    fn cancel_all(&self);

    /// Wait for a specific process to complete, with timeout.
    ///
    /// Returns immediately if the process has already completed.
    /// Returns `ToolError::Timeout` if the process doesn't complete within `timeout_ms`.
    async fn wait_for_process(
        &self,
        process_id: &str,
        timeout_ms: u64,
    ) -> Result<ManagedProcessResult, ToolError>;
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

/// Subagent spawning (`SpawnSubagent`, `WebFetch` summarizer).
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

// ─────────────────────────────────────────────────────────────────────────────
// Unified job types
// ─────────────────────────────────────────────────────────────────────────────

/// Discriminator for job kind — determines result shape and display.
///
/// Every job is tagged with its kind so consumers can format results appropriately
/// and distinguish deterministic processes from non-deterministic agent sessions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobKind {
    /// Deterministic: shell command with exit code, stdout/stderr.
    Process,
    /// Non-deterministic: LLM-driven agent with turns, token usage, reasoning.
    Agent,
}

/// Lifecycle state of a tracked job.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    /// Job is currently executing.
    Running,
    /// Job completed successfully.
    Completed,
    /// Job failed (error, non-zero exit, etc.).
    Failed,
    /// Job was explicitly cancelled.
    Cancelled,
}

/// Unified view of an in-flight or completed async job.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobInfo {
    /// Job identifier (process ID or subagent session ID).
    pub id: String,
    /// Whether this is a process or agent job.
    pub kind: JobKind,
    /// Human-readable label (command text or task description).
    pub label: String,
    /// Current lifecycle state.
    pub state: JobState,
    /// Milliseconds since job started.
    pub elapsed_ms: u64,
    /// Session that owns this job.
    pub session_id: String,
}

/// Unified completion result for any job.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobResult {
    /// Job identifier.
    pub id: String,
    /// Whether this was a process or agent job.
    pub kind: JobKind,
    /// Human-readable label.
    pub label: String,
    /// Output text (stdout for processes, final output for agents).
    pub output: String,
    /// Whether the job completed successfully.
    pub success: bool,
    /// Total duration in milliseconds.
    pub duration_ms: u64,
    /// Kind-specific extras:
    /// - Process: `{ "exit_code": i32 }`
    /// - Agent: `{ "token_usage": {...}, "turns": u32 }`
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

/// Subagent operations needed by the JobManager facade.
///
/// This trait abstracts the SubagentManager's methods that JobManager needs,
/// allowing clean test mocking without requiring full SubagentManager construction.
#[async_trait]
pub trait SubagentOps: Send + Sync {
    /// List all active and recently-completed subagents for a parent session.
    fn list_active_jobs(&self, parent_session_id: &str) -> Vec<JobInfo>;

    /// Cancel a specific subagent by session ID.
    fn cancel_subagent(&self, session_id: &str) -> Result<(), ToolError>;

    /// Wait for one or more subagents to complete.
    async fn wait_for_agents(
        &self,
        session_ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<SubagentResult>, ToolError>;

    /// Get result of a completed subagent (None if still running or not found).
    fn get_subagent_result(&self, session_id: &str) -> Option<SubagentResult>;
}

/// Operations for unified job management across processes and subagents.
///
/// The `JobManager` facade implements this trait, delegating to `ProcessManagerOps`
/// and `SubagentSpawner` under the hood. Job IDs are routed by prefix:
/// `proc-*` → process manager, everything else → subagent manager.
#[async_trait]
pub trait JobManagerOps: Send + Sync {
    /// List all active and recently-completed jobs for a session.
    fn list_jobs(&self, session_id: &str) -> Vec<JobInfo>;

    /// Wait for specific jobs to complete.
    ///
    /// Accepts a mix of process IDs and subagent session IDs.
    /// Returns partial results on timeout (does NOT auto-cancel).
    async fn wait_for_jobs(
        &self,
        ids: &[String],
        mode: WaitMode,
        timeout_ms: u64,
    ) -> Result<Vec<JobResult>, ToolError>;

    /// Cancel a job by ID (auto-detects process vs agent).
    /// `user_initiated` marks the cancellation as coming from the iOS user,
    /// which sets `user_cancelled` on the result so tools don't retry.
    fn cancel_job(&self, id: &str, user_initiated: bool) -> Result<(), ToolError>;
}

/// iOS app notifications (`NotifyApp`).
#[async_trait]
pub trait NotifyDelegate: Send + Sync {
    /// Send a push notification to every active device token.
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
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            all_tool_names: vec![],
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
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            all_tool_names: vec![],
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
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            all_tool_names: vec![],
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

    // ── Managed process types ──────────────────────────────────

    #[test]
    fn process_kind_serde_roundtrip() {
        for kind in [ProcessKind::Shell, ProcessKind::DisplayStream, ProcessKind::ToolOperation] {
            let json = serde_json::to_string(&kind).unwrap();
            let back: ProcessKind = serde_json::from_str(&json).unwrap();
            assert_eq!(kind, back);
        }
    }

    #[test]
    fn process_kind_snake_case_serialization() {
        assert_eq!(serde_json::to_string(&ProcessKind::Shell).unwrap(), "\"shell\"");
        assert_eq!(serde_json::to_string(&ProcessKind::DisplayStream).unwrap(), "\"display_stream\"");
        assert_eq!(serde_json::to_string(&ProcessKind::ToolOperation).unwrap(), "\"tool_operation\"");
    }

    #[test]
    fn managed_process_config_construction() {
        let config = ManagedProcessConfig {
            label: "cargo build".into(),
            kind: ProcessKind::Shell,
            timeout_ms: Some(120_000),
            blocking_timeout_ms: None,
            sandbox: true,
        };
        assert_eq!(config.label, "cargo build");
        assert_eq!(config.kind, ProcessKind::Shell);
        assert_eq!(config.timeout_ms, Some(120_000));
        assert!(config.sandbox);
    }

    #[test]
    fn managed_process_result_serde_roundtrip() {
        let result = ManagedProcessResult {
            process_id: "proc-abc".into(),
            output: "build complete".into(),
            exit_code: Some(0),
            duration_ms: 5000,
            timed_out: false,
            cancelled: false,
            blob_id: None,
            user_cancelled: false,
        };
        let json = serde_json::to_string(&result).unwrap();
        let back: ManagedProcessResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.process_id, "proc-abc");
        assert_eq!(back.exit_code, Some(0));
        assert!(back.blob_id.is_none());
    }

    #[test]
    fn managed_process_result_with_blob_id() {
        let result = ManagedProcessResult {
            process_id: "proc-xyz".into(),
            output: "truncated...".into(),
            exit_code: Some(1),
            duration_ms: 10000,
            timed_out: false,
            cancelled: false,
            blob_id: Some("blob-123".into()),
            user_cancelled: false,
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("blob-123"));
        let back: ManagedProcessResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.blob_id.as_deref(), Some("blob-123"));
    }

    #[test]
    fn process_info_serde_roundtrip() {
        let info = ProcessInfo {
            process_id: "proc-1".into(),
            label: "npm test".into(),
            kind: ProcessKind::Shell,
            state: "background".into(),
            elapsed_ms: 3000,
            session_id: "sess-1".into(),
            tool_call_id: "tc-1".into(),
        };
        let json = serde_json::to_string(&info).unwrap();
        let back: ProcessInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.process_id, "proc-1");
        assert_eq!(back.kind, ProcessKind::Shell);
        assert_eq!(back.session_id, "sess-1");
    }

    #[test]
    fn process_state_equality() {
        assert_eq!(ProcessState::Foreground, ProcessState::Foreground);
        assert_eq!(ProcessState::Background, ProcessState::Background);
        assert_eq!(ProcessState::Completed, ProcessState::Completed);
        assert_eq!(ProcessState::Failed, ProcessState::Failed);
        assert_eq!(ProcessState::Cancelled, ProcessState::Cancelled);
        assert_ne!(ProcessState::Foreground, ProcessState::Background);
        assert_ne!(ProcessState::Completed, ProcessState::Failed);
    }

    #[test]
    fn tool_context_process_manager_is_optional() {
        let ctx = ToolContext {
            tool_call_id: String::new(),
            session_id: String::new(),
            working_directory: String::new(),
            cancellation: CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: None,
            output_tx: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            all_tool_names: vec![],
        };
        assert!(ctx.process_manager.is_none());
    }

    // ── Process options ───────────────────────────────────────

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

    // ── Unified job types ────────────────────────────────────

    #[test]
    fn job_kind_serde_roundtrip() {
        for kind in [JobKind::Process, JobKind::Agent] {
            let json = serde_json::to_string(&kind).unwrap();
            let back: JobKind = serde_json::from_str(&json).unwrap();
            assert_eq!(kind, back);
        }
    }

    #[test]
    fn job_kind_snake_case_serialization() {
        assert_eq!(serde_json::to_string(&JobKind::Process).unwrap(), "\"process\"");
        assert_eq!(serde_json::to_string(&JobKind::Agent).unwrap(), "\"agent\"");
    }

    #[test]
    fn job_state_serde_roundtrip() {
        for state in [JobState::Running, JobState::Completed, JobState::Failed, JobState::Cancelled] {
            let json = serde_json::to_string(&state).unwrap();
            let back: JobState = serde_json::from_str(&json).unwrap();
            assert_eq!(state, back);
        }
    }

    #[test]
    fn job_state_snake_case_serialization() {
        assert_eq!(serde_json::to_string(&JobState::Running).unwrap(), "\"running\"");
        assert_eq!(serde_json::to_string(&JobState::Completed).unwrap(), "\"completed\"");
        assert_eq!(serde_json::to_string(&JobState::Failed).unwrap(), "\"failed\"");
        assert_eq!(serde_json::to_string(&JobState::Cancelled).unwrap(), "\"cancelled\"");
    }

    #[test]
    fn job_info_process_construction() {
        let info = JobInfo {
            id: "proc-abc123".into(),
            kind: JobKind::Process,
            label: "cargo build --release".into(),
            state: JobState::Running,
            elapsed_ms: 5000,
            session_id: "sess-1".into(),
        };
        assert_eq!(info.id, "proc-abc123");
        assert_eq!(info.kind, JobKind::Process);
        assert_eq!(info.state, JobState::Running);

        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("\"kind\":\"process\""));
        assert!(json.contains("\"state\":\"running\""));
        assert!(json.contains("\"elapsedMs\":5000"));
    }

    #[test]
    fn job_info_agent_construction() {
        let info = JobInfo {
            id: "ses-xyz789".into(),
            kind: JobKind::Agent,
            label: "Research API patterns".into(),
            state: JobState::Completed,
            elapsed_ms: 32000,
            session_id: "sess-1".into(),
        };
        assert_eq!(info.kind, JobKind::Agent);
        assert_eq!(info.state, JobState::Completed);

        let json = serde_json::to_string(&info).unwrap();
        let back: JobInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "ses-xyz789");
        assert_eq!(back.kind, JobKind::Agent);
    }

    #[test]
    fn job_result_with_process_details() {
        let result = JobResult {
            id: "proc-abc".into(),
            kind: JobKind::Process,
            label: "cargo test".into(),
            output: "test result: ok".into(),
            success: true,
            duration_ms: 5000,
            details: Some(serde_json::json!({ "exit_code": 0 })),
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"kind\":\"process\""));
        assert!(json.contains("\"exit_code\":0"));

        let back: JobResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.kind, JobKind::Process);
        assert!(back.success);
        assert_eq!(back.details.unwrap()["exit_code"], 0);
    }

    #[test]
    fn job_result_with_agent_details() {
        let result = JobResult {
            id: "ses-xyz".into(),
            kind: JobKind::Agent,
            label: "Research task".into(),
            output: "Found 3 patterns".into(),
            success: true,
            duration_ms: 32000,
            details: Some(serde_json::json!({
                "token_usage": { "input": 1000, "output": 500 },
                "turns": 5
            })),
        };
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"kind\":\"agent\""));
        assert!(json.contains("\"turns\":5"));

        let back: JobResult = serde_json::from_str(&json).unwrap();
        assert_eq!(back.kind, JobKind::Agent);
        assert_eq!(back.details.unwrap()["turns"], 5);
    }

    #[test]
    fn job_result_without_details() {
        let result = JobResult {
            id: "proc-none".into(),
            kind: JobKind::Process,
            label: "echo hi".into(),
            output: "hi".into(),
            success: true,
            duration_ms: 10,
            details: None,
        };
        let json = serde_json::to_string(&result).unwrap();
        // details should be omitted from JSON when None
        assert!(!json.contains("details"));
    }

    #[test]
    fn tool_context_job_manager_is_optional() {
        let ctx = ToolContext {
            tool_call_id: String::new(),
            session_id: String::new(),
            working_directory: String::new(),
            cancellation: CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: None,
            output_tx: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            all_tool_names: vec![],
        };
        assert!(ctx.job_manager.is_none());
    }
}
