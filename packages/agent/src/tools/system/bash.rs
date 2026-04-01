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

        // Forwarder task: channel → buffer. Exits when tx is dropped (process completes).
        let _ = tokio::spawn(async move {
            while let Some(chunk) = output_rx.recv().await {
                buffer_for_forwarder.push(chunk);
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
            Some(result) => {
                // Completed within blocking timeout — inline the result.
                let exit_code = result.exit_code.unwrap_or(-1);

                Ok(TronToolResult {
                    content: ToolResultBody::Text(result.output),
                    details: Some(json!({
                        "command": command,
                        "exitCode": exit_code,
                        "duration": result.duration_ms,
                        "description": description,
                        "processId": process_id,
                        "blobId": result.blob_id,
                    })),
                    is_error: if exit_code != 0 { Some(true) } else { None },
                    stop_turn: None,
                })
            }
            None => {
                // Auto-backgrounded — process continues running.
                Ok(TronToolResult {
                    content: ToolResultBody::Text(format!(
                        "Process backgrounded: {process_id}\nCommand: {command}\n\n\
                         Results will be automatically available at your next turn. \
                         Only use the Wait tool if you need the output before proceeding."
                    )),
                    details: Some(json!({
                        "command": command,
                        "processId": process_id,
                        "description": description,
                    })),
                    is_error: None,
                    stop_turn: None,
                })
            }
        }
    }
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
            return Ok(error_result(reason));
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
                return Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(&combined),
                    ]),
                    details: Some(json!({
                        "command": docker_cmd,
                        "exitCode": docker_output.exit_code,
                        "durationMs": docker_output.duration_ms,
                        "sandbox": "docker",
                        "image": self.sandbox_default_image,
                        "description": description,
                    })),
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
            "description": description,
            "blobId": blob_id,
        });
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
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> crate::tools::traits::ProcessOutput + Send + Sync>,
    }

    impl MockRunner {
        fn ok(stdout: &str) -> Self {
            let s = stdout.to_owned();
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: s.clone(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn with_exit(stdout: &str, exit_code: i32) -> Self {
            let s = stdout.to_owned();
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: s.clone(),
                    stderr: String::new(),
                    exit_code,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn with_timeout() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: String::new(),
                    stderr: String::new(),
                    exit_code: 124,
                    duration_ms: 120_000,
                    timed_out: true,
                    interrupted: false,
                }),
            }
        }

        fn with_interrupt() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: "partial output".into(),
                    stderr: String::new(),
                    exit_code: 130,
                    duration_ms: 50,
                    timed_out: false,
                    interrupted: true,
                }),
            }
        }

        fn large_output() -> Self {
            Self {
                handler: Box::new(|_| crate::tools::traits::ProcessOutput {
                    stdout: "x".repeat(500_000),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }

        fn sized_output(size: usize) -> Self {
            Self {
                handler: Box::new(move |_| crate::tools::traits::ProcessOutput {
                    stdout: "a".repeat(size),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }),
            }
        }
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(
            &self,
            command: &str,
            _opts: &ProcessOptions,
        ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    struct MockBlobStore {
        stored: Mutex<Vec<Vec<u8>>>,
        call_count: AtomicUsize,
        should_fail: bool,
    }

    impl MockBlobStore {
        fn new() -> Self {
            Self {
                stored: Mutex::new(Vec::new()),
                call_count: AtomicUsize::new(0),
                should_fail: false,
            }
        }

        fn failing() -> Self {
            Self {
                stored: Mutex::new(Vec::new()),
                call_count: AtomicUsize::new(0),
                should_fail: true,
            }
        }

        fn call_count(&self) -> usize {
            self.call_count.load(Ordering::SeqCst)
        }

        fn last_stored_size(&self) -> Option<usize> {
            self.stored.lock().unwrap().last().map(std::vec::Vec::len)
        }
    }

    #[async_trait]
    impl BlobStore for MockBlobStore {
        async fn store(&self, content: &[u8], _mime_type: &str) -> Result<String, ToolError> {
            let _ = self.call_count.fetch_add(1, Ordering::SeqCst);
            if self.should_fail {
                return Err(ToolError::Internal {
                    message: "blob store error".into(),
                });
            }
            self.stored.lock().unwrap().push(content.to_vec());
            Ok("blob_test123".into())
        }
    }

    use crate::tools::testutil::{extract_text, make_ctx};

    // ── Existing tests (unchanged behavior, updated constructor) ──

    #[tokio::test]
    async fn simple_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("hello world")), None);
        let r = tool
            .execute(json!({"command": "echo hello"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("hello world"));
    }

    #[tokio::test]
    async fn nonzero_exit_code() {
        let tool = BashTool::new(Arc::new(MockRunner::with_exit("error output", 1)), None);
        let r = tool
            .execute(json!({"command": "false"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert_eq!(r.details.unwrap()["exitCode"], 1);
    }

    #[tokio::test]
    async fn timeout_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_timeout()), None);
        let r = tool
            .execute(json!({"command": "sleep 999"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["durationMs"], 120_000);
    }

    #[tokio::test]
    async fn timeout_capped_at_max() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "timeout": 999_999_999}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn default_timeout_when_not_specified() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn output_truncation() {
        let tool = BashTool::new(Arc::new(MockRunner::large_output()), None);
        let r = tool
            .execute(json!({"command": "cat bigfile"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
        assert!(r.details.unwrap()["truncated"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn missing_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn empty_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": ""}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn cancellation_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_interrupt()), None);
        let r = tool
            .execute(json!({"command": "long-running"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["interrupted"].as_bool().unwrap());
        assert_eq!(d["exitCode"], 130);
    }

    #[tokio::test]
    async fn description_stored_in_details() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "description": "list files"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.details.unwrap()["description"], "list files");
    }

    #[tokio::test]
    async fn details_include_exit_code_and_duration() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("out")), None);
        let r = tool
            .execute(json!({"command": "echo"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["exitCode"], 0);
        assert!(d["durationMs"].as_u64().is_some());
    }

    // Dangerous pattern tests

    #[tokio::test]
    async fn blocks_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "rm -rf /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("destructive"));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "sudo rm -rf /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_rm_rf_star() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "rm -rf /*"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_fork_bomb() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": ":(){ :|: & };:"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_dd_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "dd if=/dev/zero of=/dev/sda"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_mkfs() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "mkfs.ext4 /dev/sda"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_chmod_777_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "chmod 777 /"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_redirect_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "> /dev/sda"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_usr() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(json!({"command": "sudo rm -rf /usr"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn allows_safe_commands() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")), None);
        for cmd in ["ls -la", "git status", "rm file.txt", "cat /etc/hosts"] {
            let r = tool
                .execute(json!({"command": cmd}), &make_ctx())
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "Command incorrectly blocked: {cmd}");
        }
    }

    #[test]
    fn all_danger_patterns_compile() {
        assert_eq!(
            DANGER_PATTERNS.len(),
            8,
            "expected 8 danger patterns, got {}",
            DANGER_PATTERNS.len()
        );
    }

    // ── Blob storage tests ──

    #[tokio::test]
    async fn blob_store_called_for_large_output() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 1);
        let d = r.details.as_ref().unwrap();
        assert_eq!(d["blobId"], "blob_test123");
        let text = extract_text(&r);
        assert!(text.contains("blob_test123"));
    }

    #[tokio::test]
    async fn inline_output_below_threshold() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(10_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "small"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 0);
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn output_at_exact_threshold_not_blobbed() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(INLINE_OUTPUT_LIMIT)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "exact"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 0);
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn blob_store_error_graceful_fallback() {
        let store = Arc::new(MockBlobStore::failing());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(store.call_count(), 1);
        let d = r.details.as_ref().unwrap();
        assert!(d["blobId"].is_null());
        // Still returns head+tail
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
    }

    #[tokio::test]
    async fn no_blob_store_still_truncates() {
        let tool = BashTool::new(Arc::new(MockRunner::sized_output(50_000)), None);
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("chars omitted"));
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    #[tokio::test]
    async fn hard_truncation_before_blob() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(500_000)),
            Some(store.clone()),
        );
        let _r = tool
            .execute(json!({"command": "huge"}), &make_ctx())
            .await
            .unwrap();
        // Content passed to blob store should be ≤ MAX_OUTPUT_CHARS + truncation marker
        let stored_size = store.last_stored_size().unwrap();
        assert!(stored_size <= MAX_OUTPUT_CHARS + 30);
    }

    #[tokio::test]
    async fn head_tail_content_correct() {
        let tool = BashTool::new(Arc::new(MockRunner::sized_output(60_000)), None);
        let r = tool
            .execute(json!({"command": "test"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        // Head should start with 'a' repeated chars (our mock output)
        assert!(text.starts_with("aaaa"));
        // Tail should end with 'a' repeated chars
        assert!(text.ends_with("aaaa"));
        // Should have omission marker in the middle
        assert!(text.contains("chars omitted"));
        // Total should be much less than 60K
        assert!(text.len() < 35_000);
    }

    #[tokio::test]
    async fn head_tail_utf8_safe() {
        // Output with multi-byte chars (emoji) throughout
        let runner = Arc::new(MockRunner {
            handler: Box::new(|_| {
                // 🎉 is 4 bytes each, create enough to exceed INLINE_OUTPUT_LIMIT
                let emoji_str = "🎉".repeat(10_000); // 40K bytes
                crate::tools::traits::ProcessOutput {
                    stdout: emoji_str,
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }),
        });
        let tool = BashTool::new(runner, None);
        let r = tool
            .execute(json!({"command": "emoji"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        // Must be valid UTF-8 (extract_text would panic otherwise)
        assert!(!text.is_empty());
        assert!(text.contains("chars omitted"));
    }

    #[tokio::test]
    async fn blob_details_json_shape() {
        let store = Arc::new(MockBlobStore::new());
        let tool = BashTool::new(
            Arc::new(MockRunner::sized_output(50_000)),
            Some(store.clone()),
        );
        let r = tool
            .execute(json!({"command": "big"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["blobId"].is_string());
        assert_eq!(d["blobId"].as_str().unwrap(), "blob_test123");
    }

    #[tokio::test]
    async fn blob_details_null_when_below_threshold() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("small")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["blobId"].is_null());
    }

    // ── New: stdin, env, shell tests ──

    #[tokio::test]
    async fn stdin_passed_through() {
        // Mock that echoes back the command (stdin is used by the runner, not visible here)
        let runner = Arc::new(MockRunner::ok("stdin works"));
        let tool = BashTool::new(runner, None);
        let r = tool
            .execute(
                json!({"command": "cat", "stdin": "hello from stdin"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_vars_in_params() {
        // Verify env vars are passed to ProcessOptions (mock doesn't use them, just verifying no errors)
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo $FOO", "env": {"FOO": "bar", "BAZ": "qux"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "bash"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_zsh() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "zsh"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn shell_param_invalid_defaults_to_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "powershell"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn timeout_max_raised_to_3600s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        // Should accept up to 3_600_000ms
        let r = tool
            .execute(
                json!({"command": "ls", "timeout": 3_600_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    // ── PTY timeout cap tests ──

    #[tokio::test]
    async fn interactive_default_timeout_30s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        // Default interactive timeout is 30s (not 120s default)
    }

    #[tokio::test]
    async fn interactive_timeout_capped_at_120s() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        // Even if user requests 600s, PTY caps at 120s
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true, "timeout": 600_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn interactive_custom_timeout_within_cap() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        // 60s is within PTY cap, should be accepted
        let r = tool
            .execute(
                json!({"command": "echo test", "interactive": true, "timeout": 60_000}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    // ── PATH override guardrail tests ──

    #[tokio::test]
    async fn env_path_override_tmp_blocked() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/tmp/evil:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("suspicious"));
    }

    #[tokio::test]
    async fn env_path_override_hidden_dir_blocked() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/home/user/.evil/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn env_path_override_safe_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/usr/local/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_path_override_cargo_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/Users/me/.cargo/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_path_override_nvm_allowed() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "env": {"PATH": "/Users/me/.nvm/versions/node/v20/bin:/usr/bin"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn env_non_path_vars_unaffected() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo $FOO", "env": {"FOO": "/tmp/evil", "BAR": "test"}}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none(), "Non-PATH env vars should not be checked");
    }

    // ── ptyInput audit tests ──

    #[tokio::test]
    async fn pty_input_logged_in_details() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({
                    "command": "echo test",
                    "interactive": true,
                    "ptyInput": [{"wait": "continue?", "send": "y\n"}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d["interactive"].as_bool().unwrap());
        let pty_audit = d["ptyInput"].as_array().unwrap();
        assert_eq!(pty_audit.len(), 1);
        assert_eq!(pty_audit[0]["wait"], "continue?");
        assert_eq!(pty_audit[0]["send"], "y\n");
    }

    #[tokio::test]
    async fn pty_input_password_redacted() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({
                    "command": "ssh user@host",
                    "interactive": true,
                    "ptyInput": [{"wait": "password:", "send": "secret123\n"}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        let pty_audit = d["ptyInput"].as_array().unwrap();
        assert_eq!(pty_audit[0]["send"], "[REDACTED]");
    }

    #[tokio::test]
    async fn shell_logged_in_details_when_not_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test", "shell": "zsh"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["shell"], "zsh");
    }

    #[tokio::test]
    async fn shell_not_in_details_when_bash() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "echo test"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("shell").is_none() || d["shell"].is_null());
    }

    // ── is_suspicious_path unit tests ──

    #[test]
    fn suspicious_path_tmp() {
        assert!(BashTool::is_suspicious_path("/tmp/evil:/usr/bin"));
    }

    #[test]
    fn suspicious_path_hidden_dir() {
        assert!(BashTool::is_suspicious_path("/home/user/.malware/bin:/usr/bin"));
    }

    #[test]
    fn suspicious_path_var_tmp() {
        assert!(BashTool::is_suspicious_path("/var/tmp/bad:/usr/bin"));
    }

    #[test]
    fn safe_path_standard() {
        assert!(!BashTool::is_suspicious_path("/usr/local/bin:/usr/bin:/bin"));
    }

    #[test]
    fn safe_path_cargo() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.cargo/bin:/usr/bin"));
    }

    #[test]
    fn safe_path_nvm() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.nvm/versions/node/v20/bin"));
    }

    #[test]
    fn safe_path_local() {
        assert!(!BashTool::is_suspicious_path("/Users/me/.local/bin:/usr/bin"));
    }

    // ── redact_pty_input unit tests ──

    #[test]
    fn redact_pty_input_normal() {
        let pairs = vec![("continue?".into(), "y\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "y\n");
    }

    #[test]
    fn redact_pty_input_password() {
        let pairs = vec![("Enter password:".into(), "secret\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "[REDACTED]");
    }

    #[test]
    fn redact_pty_input_token() {
        let pairs = vec![("API token:".into(), "abc123\n".into())];
        let result = BashTool::redact_pty_input(&pairs);
        assert_eq!(result[0]["send"], "[REDACTED]");
    }

    // ── Sandbox tests ──

    #[tokio::test]
    async fn sandbox_true_boolean_creates_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("sandbox output")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["sandbox"], "lightweight");
    }

    #[tokio::test]
    async fn sandbox_true_string_creates_sandbox() {
        // LLMs sometimes send "true" as a string instead of boolean
        let tool = BashTool::new(Arc::new(MockRunner::ok("sandbox output")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": "true"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["sandbox"], "lightweight");
    }

    #[tokio::test]
    async fn sandbox_false_no_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(
                json!({"command": "ls", "sandbox": false}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("sandbox").is_none() || d["sandbox"].is_null());
    }

    #[tokio::test]
    async fn sandbox_no_param_no_sandbox() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let r = tool
            .execute(json!({"command": "ls"}), &make_ctx())
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert!(d.get("sandbox").is_none() || d["sandbox"].is_null());
    }

    #[tokio::test]
    async fn sandbox_settings_applied_to_docker() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None)
            .with_sandbox_settings("node:20-alpine".into(), false);
        assert_eq!(tool.sandbox_default_image, "node:20-alpine");
        assert!(!tool.sandbox_network_enabled);
    }

    #[tokio::test]
    async fn sandbox_settings_default_values() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        assert_eq!(tool.sandbox_default_image, "ubuntu:latest");
        assert!(tool.sandbox_network_enabled);
    }

    // ── PTY redaction tests ─────────────────────────────────────

    #[test]
    fn pty_redacts_password() {
        assert!(is_sensitive_prompt("Enter password:"));
        assert!(is_sensitive_prompt("PASSWORD:"));
    }

    #[test]
    fn pty_redacts_passphrase() {
        assert!(is_sensitive_prompt("Enter passphrase for key:"));
    }

    #[test]
    fn pty_redacts_token() {
        assert!(is_sensitive_prompt("Token:"));
    }

    #[test]
    fn pty_redacts_secret() {
        assert!(is_sensitive_prompt("Secret key:"));
    }

    #[test]
    fn pty_redacts_pin() {
        assert!(is_sensitive_prompt("Enter PIN:"));
    }

    #[test]
    fn pty_redacts_api_key() {
        assert!(is_sensitive_prompt("API key:"));
    }

    #[test]
    fn pty_redacts_oauth() {
        assert!(is_sensitive_prompt("OAuth credential:"));
    }

    #[test]
    fn pty_redacts_credential() {
        assert!(is_sensitive_prompt("Enter your credential:"));
    }

    #[test]
    fn pty_does_not_redact_username() {
        assert!(!is_sensitive_prompt("Enter username:"));
    }

    #[test]
    fn pty_does_not_redact_name() {
        assert!(!is_sensitive_prompt("What is your name?"));
    }

    #[test]
    fn pty_does_not_redact_file_path() {
        assert!(!is_sensitive_prompt("Enter file path:"));
    }

    #[test]
    fn pty_does_not_redact_keyboard() {
        // "key" in "keyboard" should NOT trigger
        assert!(!is_sensitive_prompt("Keyboard input:"));
    }

    #[test]
    fn pty_does_not_redact_continue_prompt() {
        assert!(!is_sensitive_prompt("Continue? [y/n]"));
    }

    // ── Async-first execution ──────────────────────────────────

    #[test]
    fn bash_schema_has_timeout_param() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        assert!(props.contains_key("timeout"), "missing timeout property");
        // wait param should be gone (replaced by timeout)
        assert!(!props.contains_key("wait"), "wait should be removed");
    }

    #[tokio::test]
    async fn bash_direct_run_returns_inline() {
        // Without ProcessManager, bash falls back to direct run
        let tool = BashTool::new(Arc::new(MockRunner::ok("hello")), None);
        let r = tool
            .execute(json!({"command": "echo hello"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("hello"));
    }

    #[tokio::test]
    async fn bash_no_process_manager_falls_back_to_sync() {
        // When process_manager is None, async-first degrades to synchronous
        let tool = BashTool::new(Arc::new(MockRunner::ok("fallback")), None);
        let ctx = make_ctx(); // process_manager is None
        let r = tool
            .execute(json!({"command": "echo fallback"}), &ctx)
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("fallback"));
    }

    #[tokio::test]
    async fn bash_interactive_always_synchronous() {
        // interactive mode should bypass async even with process_manager
        let tool = BashTool::new(Arc::new(MockRunner::ok("pty-output")), None);
        let r = tool
            .execute(json!({"command": "echo pty", "interactive": true}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("pty-output"));
    }

    #[tokio::test]
    async fn bash_stdin_always_synchronous() {
        // stdin should force synchronous
        let tool = BashTool::new(Arc::new(MockRunner::ok("piped")), None);
        let r = tool
            .execute(json!({"command": "cat", "stdin": "data"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("piped"));
    }

    #[tokio::test]
    async fn bash_async_default_with_auto_wait_fast_command() {
        // Fast commands complete within 150ms and get inlined
        let tool = BashTool::new(Arc::new(MockRunner::ok("fast-result")), None);
        let mut ctx = make_ctx();
        let pm = Arc::new(crate::runtime::orchestrator::process_manager::ProcessManager::new());
        ctx.process_manager = Some(pm);

        let r = tool
            .execute(json!({"command": "echo hello"}), &ctx)
            .await
            .unwrap();

        let text = extract_text(&r);
        // Auto-wait should have caught the fast completion and inlined the result
        assert!(text.contains("fast-result"), "expected inlined result, got: {text}");
        // Should NOT contain process ID since it completed fast
        assert!(!text.contains("proc-"), "should not return process ID for fast command");
    }

    #[tokio::test]
    async fn bash_async_dangerous_command_still_blocked() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
        let mut ctx = make_ctx();
        let pm = Arc::new(crate::runtime::orchestrator::process_manager::ProcessManager::new());
        ctx.process_manager = Some(pm);

        // Dangerous commands are blocked before async/sync dispatch
        let r = tool
            .execute(json!({"command": "rm -rf /"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
