//! `Bash` tool — shell command execution with timeout and danger detection.
//!
//! Spawns `bash -c <command>` in the working directory. Detects dangerous
//! patterns (rm -rf /, fork bombs, dd to device, etc.) and blocks them.
//! Output is truncated if it exceeds the character budget. Large outputs
//! (> `INLINE_OUTPUT_LIMIT`) are stored as blobs and replaced with
//! head + tail inline.

use std::sync::{Arc, LazyLock};

use async_trait::async_trait;
use regex::Regex;

static DANGER_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/($|\s|;|\|)",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/\*",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/(usr|etc|var|home|boot|dev|proc|sys)\b",
        r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:",
        r"dd\s+.*of=/dev/[sh]d",
        r"mkfs\.\w+\s+/dev/",
        r"chmod\s+(-[^\s]+\s+)*777\s+/$",
        r">\s*/dev/[sh]d",
    ]
    .iter()
    .map(|p| Regex::new(p).expect("danger pattern must compile"))
    .collect()
});
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{BlobStore, ProcessOptions, ProcessRunner, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::truncation::estimate_tokens;
use crate::tools::utils::validation::{get_optional_bool, get_optional_string, get_optional_u64, validate_required_string};

const DEFAULT_BLOCKING_TIMEOUT_MS: u64 = 60_000;
const MAX_BLOCKING_TIMEOUT_MS: u64 = 600_000;
const MIN_KILL_TIMEOUT_MS: u64 = 120_000;
const MAX_KILL_TIMEOUT_MS: u64 = 3_600_000;
const PTY_MAX_TIMEOUT_MS: u64 = 120_000;
const INTERACTIVE_DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MAX_OUTPUT_CHARS: usize = 5_000_000;

use crate::tools::utils::truncation::{
    safe_char_boundary, truncate_head_tail, HEAD_CHARS, INLINE_OUTPUT_LIMIT, TAIL_CHARS,
};

/// The `Bash` tool executes shell commands.
pub struct BashTool {
    runner: Arc<dyn ProcessRunner>,
    blob_store: Option<Arc<dyn BlobStore>>,
    /// Default Docker image for sandbox mode (from settings).
    sandbox_default_image: String,
    /// Whether Docker sandbox has network by default (from settings).
    sandbox_network_enabled: bool,
}

impl BashTool {
    /// Create a new `Bash` tool with the given process runner and optional blob store.
    pub fn new(runner: Arc<dyn ProcessRunner>, blob_store: Option<Arc<dyn BlobStore>>) -> Self {
        Self {
            runner,
            blob_store,
            sandbox_default_image: "ubuntu:latest".to_string(),
            sandbox_network_enabled: true,
        }
    }

    /// Configure sandbox settings (called from factory with settings values).
    #[must_use]
    pub fn with_sandbox_settings(mut self, default_image: String, network_enabled: bool) -> Self {
        self.sandbox_default_image = default_image;
        self.sandbox_network_enabled = network_enabled;
        self
    }

    fn check_dangerous(command: &str) -> Option<String> {
        for pattern in &*DANGER_PATTERNS {
            if pattern.is_match(command) {
                return Some("Potentially destructive command pattern detected".into());
            }
        }
        None
    }

    /// Check if a PATH value points to suspicious locations (e.g., /tmp, hidden dirs).
    fn is_suspicious_path(path: &str) -> bool {
        let suspicious = ["/tmp/", "/var/tmp/", "/dev/shm/"];
        for segment in path.split(':') {
            let seg = segment.trim();
            if seg.is_empty() {
                continue;
            }
            // Suspicious: starts with temp dirs or hidden dirs in home
            for prefix in &suspicious {
                if seg.starts_with(prefix) {
                    return true;
                }
            }
            // Suspicious: hidden directory path (e.g., ~/.malware/bin)
            if seg.contains("/.") && !seg.contains("/.tron") && !seg.contains("/.cargo")
                && !seg.contains("/.local") && !seg.contains("/.nvm")
                && !seg.contains("/.npm") && !seg.contains("/.bun")
                && !seg.contains("/.pyenv") && !seg.contains("/.rbenv")
                && !seg.contains("/.rustup") && !seg.contains("/.volta")
                && !seg.contains("/.go") && !seg.contains("/.deno")
            {
                return true;
            }
        }
        false
    }

    /// Redact ptyInput send values for password-like patterns in audit log.
    fn redact_pty_input(pty_input: &[(String, String)]) -> Vec<Value> {
        pty_input
            .iter()
            .map(|(wait, send)| {
                let is_sensitive = is_sensitive_prompt(wait);
                json!({
                    "wait": wait,
                    "send": if is_sensitive { "[REDACTED]" } else { send.as_str() },
                })
            })
            .collect()
    }

    /// Execute a command via ProcessManager with blocking timeout.
    ///
    /// The command blocks for up to `timeout_ms` (the `timeout` param, default 60s).
    /// If it completes within that window, the result is returned inline.
    /// If it's still running, it auto-backgrounds and returns a process ID.
    /// Output is always captured in a `SharedOutputBuffer` for on-demand streaming.
    async fn execute_managed(
        &self,
        command: &str,
        blocking_timeout_ms: u64,
        description: &Option<String>,
        shell: &str,
        env_vars: &std::collections::HashMap<String, String>,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let pm = ctx.process_manager.as_ref().ok_or(ToolError::Internal {
            message: "Managed execution requires ProcessManager (not available)".into(),
        })?;

        // Kill timeout: 2x blocking timeout, minimum 120s, capped at 1 hour.
        let kill_timeout_ms = (blocking_timeout_ms * 2).max(MIN_KILL_TIMEOUT_MS).min(MAX_KILL_TIMEOUT_MS);

        let config = crate::tools::traits::ManagedProcessConfig {
            label: command.to_owned(),
            kind: crate::tools::traits::ProcessKind::Shell,
            timeout_ms: Some(kill_timeout_ms),
            blocking_timeout_ms: Some(blocking_timeout_ms),
            sandbox: false,
        };

        // Set up output buffer for on-demand streaming.
        let output_buffer = std::sync::Arc::new(
            crate::runtime::orchestrator::output_buffer::SharedOutputBuffer::new(),
        );
        let buffer_for_forwarder = output_buffer.clone();
        let (output_tx, mut output_rx) = tokio::sync::mpsc::unbounded_channel::<String>();

        // Forwarder task: ProcessRunner chunks → buffer + ToolExecutionUpdate events.
        //
        // Emits ToolExecutionUpdate events directly via EventEmitter (not ctx.output_tx).
        // This avoids a channel lifetime conflict: ctx.output_tx is owned by the
        // ToolExecutor, and cloning it would prevent its stream_handle from completing
        // when the tool returns. By emitting directly, the ToolExecutor's channel
        // stays unused and closes cleanly.
        let forwarder_emitter = ctx.event_emitter.clone();
        let forwarder_tool_call_id = ctx.tool_call_id.clone();
        let forwarder_session_id = ctx.session_id.clone();
        let _ = tokio::spawn(async move {
            while let Some(chunk) = output_rx.recv().await {
                buffer_for_forwarder.push(chunk.clone());
                if let Some(ref emitter) = forwarder_emitter {
                    let _ = emitter.emit(crate::core::events::TronEvent::ToolExecutionUpdate {
                        base: crate::core::events::BaseEvent::now(&forwarder_session_id),
                        tool_call_id: forwarder_tool_call_id.clone(),
                        update: chunk,
                    });
                }
            }
            buffer_for_forwarder.close();
        });

        let runner = self.runner.clone();
        let cmd = command.to_owned();
        let shell = shell.to_owned();
        let env_vars = env_vars.clone();
        let working_dir = ctx.working_directory.clone();
        let cancel = ctx.cancellation.clone();

        let task: std::pin::Pin<Box<dyn std::future::Future<Output = crate::tools::traits::ManagedProcessResult> + Send>> = Box::pin(async move {
            let start = std::time::Instant::now();
            let opts = ProcessOptions {
                working_directory: working_dir,
                timeout_ms: kill_timeout_ms,
                cancellation: cancel,
                env: env_vars,
                stdin: None,
                shell,
                interactive: false,
                pty_input: Vec::new(),
                output_tx: Some(output_tx),
            };

            match runner.run_command(&cmd, &opts).await {
                Ok(output) => {
                    let mut combined = output.stdout;
                    if !output.stderr.is_empty() {
                        if !combined.is_empty() { combined.push('\n'); }
                        combined.push_str(&output.stderr);
                    }
                    crate::tools::traits::ManagedProcessResult {
                        process_id: String::new(),
                        output: combined,
                        exit_code: Some(output.exit_code),
                        duration_ms: start.elapsed().as_millis() as u64,
                        timed_out: output.timed_out,
                        cancelled: output.interrupted,
                        blob_id: None,
                        user_cancelled: false,
                    }
                }
                Err(e) => crate::tools::traits::ManagedProcessResult {
                    process_id: String::new(),
                    output: e.to_string(),
                    exit_code: None,
                    duration_ms: start.elapsed().as_millis() as u64,
                    timed_out: false,
                    cancelled: false,
                    blob_id: None,
                    user_cancelled: false,
                },
            }
        });

        let handle = pm
            .spawn_managed(
                &ctx.session_id,
                &ctx.tool_call_id,
                config,
                task,
            )
            .await?;

        let process_id = handle.process_id.clone();

        // Register the output buffer for on-demand streaming via job.subscribe RPC.
        if let Some(ref registry) = ctx.output_buffer_registry {
            registry.register(&process_id, &ctx.tool_call_id, output_buffer);
        }

        match handle.result {
            Some(result) if result.user_cancelled => {
                // User interrupted from iOS — tell the agent not to retry.
                let output = if result.output.is_empty() {
                    format!("[Interrupted by user] Command `{command}` was cancelled. Do not retry — the user intentionally stopped this command.")
                } else {
                    format!("{}\n\n[Interrupted by user] Command was cancelled.", result.output)
                };

                Ok(TronToolResult {
                    content: ToolResultBody::Text(output),
                    details: Some(json!({
                        "command": command,
                        "exitCode": -1,
                        "duration": result.duration_ms,
                        "description": description,
                        "processId": process_id,
                        "interrupted": true,
                        "userCancelled": true,
                        "errorClass": "interrupted",
                    })),
                    is_error: Some(true),
                    stop_turn: None,
                })
            }
            Some(result) => {
                // Completed within blocking timeout — inline the result.
                let exit_code = result.exit_code.unwrap_or(-1);
                let error_class = classify_bash_error(
                    result.exit_code,
                    &result.output,
                    result.timed_out,
                );
                let mut details = json!({
                    "command": command,
                    "exitCode": exit_code,
                    "duration": result.duration_ms,
                    "description": description,
                    "processId": process_id,
                    "blobId": result.blob_id,
                    "timedOut": result.timed_out,
                });
                if let Some(class) = error_class {
                    details["errorClass"] = json!(class);
                }

                Ok(TronToolResult {
                    content: ToolResultBody::Text(result.output),
                    details: Some(details),
                    is_error: if exit_code != 0 { Some(true) } else { None },
                    stop_turn: None,
                })
            }
            None => {
                // Backgrounded — process continues running.
                let user_initiated = handle.backgrounded == Some(crate::tools::traits::BackgroundReason::UserAction);
                let message = if user_initiated {
                    format!(
                        "[Backgrounded by user] Process {process_id}\nCommand: {command}\n\n\
                         The user manually backgrounded this command. It continues running. \
                         Results will be automatically available at your next turn."
                    )
                } else {
                    format!(
                        "Process backgrounded: {process_id}\nCommand: {command}\n\n\
                         Results will be automatically available at your next turn. \
                         Only use the Wait tool if you need the output before proceeding."
                    )
                };

                Ok(TronToolResult {
                    content: ToolResultBody::Text(message),
                    details: Some(json!({
                        "command": command,
                        "processId": process_id,
                        "description": description,
                        "backgrounded": true,
                        "backgroundedByUser": user_initiated,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
        }
    }
}

/// Classify a bash execution failure into a structured error class.
///
/// Returns `Some(class)` when the failure matches a known pattern, `None`
/// otherwise. Called server-side so iOS can render a structured error chip
/// without scanning stderr text.
///
/// Classes:
/// - `"timeout"`: command exceeded its blocking/kill timeout
/// - `"permission_denied"`: stderr indicates permission / EACCES failure
/// - `"blocked"`: command matched a dangerous pattern and was refused
pub(crate) fn classify_bash_error(
    exit_code: Option<i32>,
    stderr: &str,
    timed_out: bool,
) -> Option<&'static str> {
    if timed_out {
        return Some("timeout");
    }
    if exit_code != Some(0) {
        // Permission denied is a common stderr substring across OSes.
        let lower = stderr.to_lowercase();
        if lower.contains("permission denied") || lower.contains("eacces") {
            return Some("permission_denied");
        }
    }
    None
}

/// Check if a PTY prompt string indicates sensitive input.
///
/// Uses phrase matching for ambiguous words like "key" to avoid false
/// positives (e.g., "api key" redacts but "keyboard" does not).
fn is_sensitive_prompt(prompt: &str) -> bool {
    let lower = prompt.to_lowercase();
    // Single-word triggers (unambiguous)
    let single_words = ["password", "passphrase", "secret", "token", "credential", "pin"];
    for word in single_words {
        if lower.contains(word) {
            return true;
        }
    }
    // Phrase triggers (disambiguate "key" from "keyboard")
    let phrases = ["api key", "secret key", "ssh key", "private key", "oauth"];
    for phrase in phrases {
        if lower.contains(phrase) {
            return true;
        }
    }
    false
}


#[async_trait]
impl TronTool for BashTool {
    fn name(&self) -> &str {
        "Bash"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Shell
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Bash",
            "Execute a shell command. Commands block for up to `timeout` milliseconds (default 60 seconds). \
             If the command completes within the timeout, the result is returned inline. If it's still running, \
             it automatically moves to the background and results are injected on your next turn. \
             Commands that are potentially destructive require confirmation.\n\n\
             Parameters:\n\
             - **command** (required): The shell command to execute.\n\
             - **timeout** (optional): How long to wait before auto-backgrounding in milliseconds (default 60000). Set higher for builds/tests. Set 0 to background immediately.\n\
             - **description** (optional): Brief description of what the command does.\n\
             - **stdin** (optional): Data to pipe to the command's stdin.\n\
             - **env** (optional): Environment variables as key-value object.\n\
             - **shell** (optional): Shell to use — \"bash\" (default), \"zsh\", or \"sh\".\n\
             - **interactive** (optional): Run in PTY mode for commands that need a terminal.\n\
             - **ptyInput** (optional): Pattern-response pairs for interactive prompts. Array of {wait, send} objects.",
        )
        .required_property("command", json!({"type": "string", "description": "The shell command to execute"}))
        .property("timeout", json!({"type": "number", "description": "How long to block before auto-backgrounding, in milliseconds (default 60000). Set higher for builds/tests, 0 for immediate background."}))
        .property("description", json!({"type": "string", "description": "Brief description of what the command does"}))
        .property("stdin", json!({"type": "string", "description": "Data to pipe to the command's stdin"}))
        .property("env", json!({"type": "object", "description": "Environment variables", "additionalProperties": {"type": "string"}}))
        .property("shell", json!({"type": "string", "description": "Shell to use", "enum": ["bash", "zsh", "sh"], "default": "bash"}))
        .property("interactive", json!({"type": "boolean", "description": "Run in PTY mode for interactive commands", "default": false}))
        .property("ptyInput", json!({
            "type": "array",
            "description": "Pattern-response pairs for interactive prompts",
            "items": {
                "type": "object",
                "properties": {
                    "wait": {"type": "string", "description": "Pattern to wait for in output"},
                    "send": {"type": "string", "description": "Text to send when pattern matches"}
                },
                "required": ["wait", "send"]
            }
        }))
        .property("sandbox", json!({
            "description": "Run in sandbox. true = lightweight temp dir sandbox, \"docker\" = Docker container sandbox.",
            "oneOf": [
                {"type": "boolean"},
                {"type": "string", "enum": ["docker"]}
            ]
        }))
        .property("sandboxMounts", json!({
            "type": "array",
            "description": "Paths to symlink into the sandbox (read-only)",
            "items": {"type": "string"}
        }))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let command = match validate_required_string(&params, "command", "the shell command") {
            Ok(c) => c,
            Err(e) => return Ok(e),
        };

        // Check dangerous patterns
        if let Some(reason) = Self::check_dangerous(&command) {
            return Ok(TronToolResult {
                content: ToolResultBody::Text(reason),
                details: Some(json!({
                    "command": command,
                    "errorClass": "blocked",
                })),
                is_error: Some(true),
                stop_turn: None,
            });
        }

        let timeout_ms = get_optional_u64(&params, "timeout")
            .unwrap_or(DEFAULT_BLOCKING_TIMEOUT_MS)
            .min(MAX_BLOCKING_TIMEOUT_MS);
        let description = get_optional_string(&params, "description");

        // Parse env vars from params
        let env_vars: std::collections::HashMap<String, String> = params
            .get("env")
            .and_then(Value::as_object)
            .map(|obj| {
                obj.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();

        // Guard: block suspicious PATH overrides
        if let Some(path_val) = env_vars.get("PATH")
            && Self::is_suspicious_path(path_val)
        {
            return Ok(error_result(
                "Blocked: env overrides PATH to a suspicious location. \
                 Use absolute paths to binaries instead of modifying PATH.",
            ));
        }

        let shell = get_optional_string(&params, "shell")
            .unwrap_or_else(|| "bash".to_string());

        // Validate shell
        let shell = match shell.as_str() {
            "bash" | "zsh" | "sh" => shell,
            _ => "bash".to_string(),
        };

        let stdin = get_optional_string(&params, "stdin");
        let interactive = get_optional_bool(&params, "interactive").unwrap_or(false);

        // Parse ptyInput pattern-response pairs
        let pty_input: Vec<(String, String)> = params
            .get("ptyInput")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|item| {
                        let wait = item.get("wait")?.as_str()?.to_string();
                        let send = item.get("send")?.as_str()?.to_string();
                        Some((wait, send))
                    })
                    .collect()
            })
            .unwrap_or_default();

        // Interactive mode: shorter default timeout, capped at PTY_MAX_TIMEOUT_MS
        let timeout_ms = if interactive {
            let base = get_optional_u64(&params, "timeout")
                .unwrap_or(INTERACTIVE_DEFAULT_TIMEOUT_MS);
            base.min(PTY_MAX_TIMEOUT_MS)
        } else {
            timeout_ms
        };

        // Direct-run exceptions: these bypass ProcessManager because they
        // need direct pipe/PTY access or an ephemeral sandbox workspace.
        let sandbox_mode = params.get("sandbox");
        let direct_run = interactive
            || stdin.is_some()
            || sandbox_mode.is_some()
            || ctx.process_manager.is_none();

        if !direct_run {
            return self
                .execute_managed(
                    &command, timeout_ms, &description, &shell, &env_vars, ctx,
                )
                .await;
        }

        // Parse sandbox config
        let sandbox_mounts: Vec<String> = params
            .get("sandboxMounts")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        // If sandbox mode is enabled, create a sandbox workspace and override working_directory
        // Track which sandbox mode is active for details JSON
        let mut active_sandbox_mode: Option<&str> = None;
        let sandbox_workspace = if let Some(sandbox_val) = sandbox_mode {
            // Handle both boolean true and string "true" from LLMs
            let is_lightweight = sandbox_val.as_bool() == Some(true)
                || sandbox_val.as_str() == Some("true");
            let is_docker = sandbox_val.as_str() == Some("docker");

            if is_lightweight {
                active_sandbox_mode = Some("lightweight");
                let config = crate::tools::system::sandbox::SandboxConfig {
                    copy_paths: Vec::new(),
                    readonly_mounts: sandbox_mounts,
                };
                match crate::tools::system::sandbox::SandboxWorkspace::create(&config).await {
                    Ok(ws) => Some(ws),
                    Err(e) => return Ok(error_result(format!("Failed to create sandbox: {e}"))),
                }
            } else if is_docker {
                // Docker sandbox: build and run via docker command
                // Apply settings: use configured default image and network
                let docker_config = crate::tools::system::sandbox::DockerSandboxConfig {
                    image: self.sandbox_default_image.clone(),
                    mounts: sandbox_mounts.iter().map(|m| (m.clone(), m.clone(), "ro".to_string())).collect(),
                    network: self.sandbox_network_enabled,
                    ..Default::default()
                };
                if let Err(e) = crate::tools::system::sandbox::check_docker_available().await {
                    return Ok(error_result(e));
                }
                let docker_cmd = crate::tools::system::sandbox::build_docker_command(&command, &docker_config);
                // Replace command with docker command, run normally
                let opts = ProcessOptions {
                    working_directory: ctx.working_directory.clone(),
                    timeout_ms,
                    cancellation: ctx.cancellation.clone(),
                    env: env_vars,
                    stdin,
                    shell,
                    interactive,
                    pty_input,
                    output_tx: ctx.output_tx.clone(),
                };
                let docker_output = self.runner.run_command(&docker_cmd, &opts).await?;
                let mut combined = docker_output.stdout;
                if !docker_output.stderr.is_empty() {
                    if !combined.is_empty() { combined.push('\n'); }
                    combined.push_str(&docker_output.stderr);
                }
                let is_error = if docker_output.exit_code != 0 { Some(true) } else { None };
                let docker_error_class = classify_bash_error(
                    Some(docker_output.exit_code),
                    &docker_output.stderr,
                    docker_output.timed_out,
                );
                let mut docker_details = json!({
                    "command": docker_cmd,
                    "exitCode": docker_output.exit_code,
                    "durationMs": docker_output.duration_ms,
                    "sandbox": "docker",
                    "image": self.sandbox_default_image,
                    "description": description,
                    "timedOut": docker_output.timed_out,
                });
                if let Some(class) = docker_error_class {
                    docker_details["errorClass"] = json!(class);
                }
                return Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(&combined),
                    ]),
                    details: Some(docker_details),
                    is_error,
                    stop_turn: None,
                });
            } else {
                None
            }
        } else {
            None
        };

        let working_dir = if let Some(ref ws) = sandbox_workspace {
            ws.path.to_string_lossy().to_string()
        } else {
            ctx.working_directory.clone()
        };

        // Capture audit info before moving into opts
        let shell_used = shell.clone();
        let is_interactive = interactive;
        let pty_input_audit = if pty_input.is_empty() {
            None
        } else {
            Some(Self::redact_pty_input(&pty_input))
        };

        let opts = ProcessOptions {
            working_directory: working_dir,
            timeout_ms,
            cancellation: ctx.cancellation.clone(),
            env: env_vars,
            stdin,
            shell,
            interactive,
            pty_input,
            output_tx: ctx.output_tx.clone(),
        };

        let output = self.runner.run_command(&command, &opts).await?;

        // Cleanup sandbox if it was used
        if let Some(ws) = sandbox_workspace {
            let _ = ws.cleanup().await;
        }

        // Classify error before consuming stderr below.
        let error_class = classify_bash_error(
            Some(output.exit_code),
            &output.stderr,
            output.timed_out,
        );
        let timed_out_flag = output.timed_out;

        // Combine stdout + stderr
        let mut combined = output.stdout;
        if !output.stderr.is_empty() {
            if !combined.is_empty() {
                combined.push('\n');
            }
            combined.push_str(&output.stderr);
        }

        // Hard-truncate at MAX_OUTPUT_CHARS first
        let original_chars = combined.len();
        let hard_truncated = original_chars > MAX_OUTPUT_CHARS;
        if hard_truncated {
            let boundary = safe_char_boundary(&combined, MAX_OUTPUT_CHARS);
            combined.truncate(boundary);
            combined.push_str("\n... [output truncated]");
        }

        let is_error = if output.exit_code != 0 {
            Some(true)
        } else {
            None
        };

        // Blob storage for large outputs
        let mut blob_id: Option<String> = None;
        if combined.len() > INLINE_OUTPUT_LIMIT {
            if let Some(ref store) = self.blob_store {
                match store.store(combined.as_bytes(), "text/plain").await {
                    Ok(id) => blob_id = Some(id),
                    Err(e) => {
                        tracing::warn!(error = %e, "blob store failed, returning head+tail without blob reference");
                    }
                }
            }
            combined = truncate_head_tail(
                &combined,
                INLINE_OUTPUT_LIMIT,
                HEAD_CHARS,
                TAIL_CHARS,
                blob_id.as_deref(),
            );
        }

        let mut details = json!({
            "command": command,
            "exitCode": output.exit_code,
            "durationMs": output.duration_ms,
            "truncated": hard_truncated || original_chars > INLINE_OUTPUT_LIMIT,
            "originalChars": original_chars,
            "originalTokens": estimate_tokens(original_chars),
            "finalTokens": estimate_tokens(combined.len()),
            "interrupted": output.interrupted,
            "timedOut": timed_out_flag,
            "description": description,
            "blobId": blob_id,
        });
        if let Some(class) = error_class {
            details["errorClass"] = json!(class);
        }
        // Include shell/interactive/ptyInput in details for audit
        if shell_used != "bash" {
            details["shell"] = json!(shell_used);
        }
        if is_interactive {
            details["interactive"] = json!(true);
        }
        if let Some(ref pty_audit) = pty_input_audit {
            details["ptyInput"] = json!(pty_audit);
        }
        if let Some(sandbox) = active_sandbox_mode {
            details["sandbox"] = json!(sandbox);
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                combined,
            )]),
            details: Some(details),
            is_error,
            stop_turn: None,
        })
    }
}


#[cfg(test)]
#[path = "bash_tests.rs"]
mod tests;
