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

const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MAX_TIMEOUT_MS: u64 = 3_600_000;
const MAX_OUTPUT_CHARS: usize = 400_000;
const INLINE_OUTPUT_LIMIT: usize = 30_000;
const BLOB_HEAD_CHARS: usize = 20_000;
const BLOB_TAIL_CHARS: usize = 8_000;

/// The `Bash` tool executes shell commands.
pub struct BashTool {
    runner: Arc<dyn ProcessRunner>,
    blob_store: Option<Arc<dyn BlobStore>>,
}

impl BashTool {
    /// Create a new `Bash` tool with the given process runner and optional blob store.
    pub fn new(runner: Arc<dyn ProcessRunner>, blob_store: Option<Arc<dyn BlobStore>>) -> Self {
        Self { runner, blob_store }
    }

    fn check_dangerous(command: &str) -> Option<String> {
        for pattern in &*DANGER_PATTERNS {
            if pattern.is_match(command) {
                return Some("Potentially destructive command pattern detected".into());
            }
        }
        None
    }
}

/// Find a UTF-8-safe char boundary at or before `target` byte index.
fn safe_char_boundary(s: &str, target: usize) -> usize {
    if target >= s.len() {
        return s.len();
    }
    // floor_char_boundary is nightly-only; use char_indices
    let mut boundary = 0;
    for (i, _) in s.char_indices() {
        if i > target {
            break;
        }
        boundary = i;
    }
    boundary
}

/// Find a UTF-8-safe char boundary at or after `target` byte index (for tail start).
fn safe_char_boundary_ceil(s: &str, target: usize) -> usize {
    if target >= s.len() {
        return s.len();
    }
    for (i, _) in s.char_indices() {
        if i >= target {
            return i;
        }
    }
    s.len()
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
            "Execute a shell command. Commands that are potentially destructive require confirmation.\n\n\
             Parameters:\n\
             - **command** (required): The shell command to execute.\n\
             - **timeout** (optional): Timeout in milliseconds (default 120000, max 3600000).\n\
             - **description** (optional): Brief description of what the command does.\n\
             - **stdin** (optional): Data to pipe to the command's stdin.\n\
             - **env** (optional): Environment variables as key-value object.\n\
             - **shell** (optional): Shell to use — \"bash\" (default), \"zsh\", or \"sh\".\n\
             - **interactive** (optional): Run in PTY mode for commands that need a terminal.\n\
             - **ptyInput** (optional): Pattern-response pairs for interactive prompts. Array of {wait, send} objects.",
        )
        .required_property("command", json!({"type": "string", "description": "The shell command to execute"}))
        .property("timeout", json!({"type": "number", "description": "Timeout in milliseconds (default 120000, max 3600000)"}))
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
            .unwrap_or(DEFAULT_TIMEOUT_MS)
            .min(MAX_TIMEOUT_MS);
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

        // Interactive mode: shorter default timeout
        let timeout_ms = if interactive && get_optional_u64(&params, "timeout").is_none() {
            30_000_u64.min(MAX_TIMEOUT_MS) // 30s default for interactive
        } else {
            timeout_ms
        };

        // Parse sandbox config
        let sandbox_mode = params.get("sandbox");
        let sandbox_mounts: Vec<String> = params
            .get("sandboxMounts")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();

        // If sandbox mode is enabled, create a sandbox workspace and override working_directory
        let sandbox_workspace = if let Some(sandbox_val) = sandbox_mode {
            let is_lightweight = sandbox_val.as_bool() == Some(true);
            let is_docker = sandbox_val.as_str() == Some("docker");

            if is_lightweight {
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
                let docker_config = crate::tools::system::sandbox::DockerSandboxConfig {
                    mounts: sandbox_mounts.iter().map(|m| (m.clone(), m.clone(), "ro".to_string())).collect(),
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

        let opts = ProcessOptions {
            working_directory: working_dir,
            timeout_ms,
            cancellation: ctx.cancellation.clone(),
            env: env_vars,
            stdin,
            shell,
            interactive,
            pty_input,
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
            // Try to store in blob store
            if let Some(ref store) = self.blob_store {
                match store.store(combined.as_bytes(), "text/plain").await {
                    Ok(id) => blob_id = Some(id),
                    Err(e) => {
                        tracing::warn!(error = %e, "blob store failed, returning head+tail without blob reference");
                    }
                }
            }

            // Build head + tail inline
            let head_end = safe_char_boundary(&combined, BLOB_HEAD_CHARS);
            let tail_start = safe_char_boundary_ceil(&combined, combined.len() - BLOB_TAIL_CHARS);
            let omitted = tail_start - head_end;

            let marker = if let Some(ref id) = blob_id {
                format!("\n\n... [{omitted} chars omitted — stored as {id}] ...\n\n")
            } else {
                format!("\n\n... [{omitted} chars omitted] ...\n\n")
            };

            let mut inline =
                String::with_capacity(head_end + marker.len() + (combined.len() - tail_start));
            inline.push_str(&combined[..head_end]);
            inline.push_str(&marker);
            inline.push_str(&combined[tail_start..]);
            combined = inline;
        }

        let details = json!({
            "command": command,
            "exitCode": output.exit_code,
            "durationMs": output.duration_ms,
            "truncated": hard_truncated || blob_id.is_some(),
            "originalChars": original_chars,
            "originalTokens": estimate_tokens(original_chars),
            "finalTokens": estimate_tokens(combined.len()),
            "interrupted": output.interrupted,
            "description": description,
            "blobId": blob_id,
        });

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
}
