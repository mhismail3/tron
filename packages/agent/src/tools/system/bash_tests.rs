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
        .execute(json!({"command": "echo test", "shell": "zsh"}), &make_ctx())
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
        .execute(json!({"command": "ls", "timeout": 3_600_000}), &make_ctx())
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
    assert!(
        r.is_error.is_none(),
        "Non-PATH env vars should not be checked"
    );
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
        .execute(json!({"command": "echo test", "shell": "zsh"}), &make_ctx())
        .await
        .unwrap();
    let d = r.details.unwrap();
    assert_eq!(d["shell"], "zsh");
}

#[tokio::test]
async fn shell_not_in_details_when_bash() {
    let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
    let r = tool
        .execute(json!({"command": "echo test"}), &make_ctx())
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
    assert!(BashTool::is_suspicious_path(
        "/home/user/.malware/bin:/usr/bin"
    ));
}

#[test]
fn suspicious_path_var_tmp() {
    assert!(BashTool::is_suspicious_path("/var/tmp/bad:/usr/bin"));
}

#[test]
fn safe_path_standard() {
    assert!(!BashTool::is_suspicious_path(
        "/usr/local/bin:/usr/bin:/bin"
    ));
}

#[test]
fn safe_path_cargo() {
    assert!(!BashTool::is_suspicious_path(
        "/Users/me/.cargo/bin:/usr/bin"
    ));
}

#[test]
fn safe_path_nvm() {
    assert!(!BashTool::is_suspicious_path(
        "/Users/me/.nvm/versions/node/v20/bin"
    ));
}

#[test]
fn safe_path_local() {
    assert!(!BashTool::is_suspicious_path(
        "/Users/me/.local/bin:/usr/bin"
    ));
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
        .execute(json!({"command": "ls", "sandbox": true}), &make_ctx())
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
        .execute(json!({"command": "ls", "sandbox": "true"}), &make_ctx())
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
        .execute(json!({"command": "ls", "sandbox": false}), &make_ctx())
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
        .execute(
            json!({"command": "echo pty", "interactive": true}),
            &make_ctx(),
        )
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
async fn bash_managed_fast_command_returns_inline() {
    // Fast commands complete within the blocking timeout and get inlined
    let tool = BashTool::new(Arc::new(MockRunner::ok("fast-result")), None);
    let mut ctx = make_ctx();
    let pm = Arc::new(crate::runtime::orchestrator::process_manager::ProcessManager::new());
    ctx.process_manager = Some(pm);

    let r = tool
        .execute(json!({"command": "echo hello"}), &ctx)
        .await
        .unwrap();

    let text = extract_text(&r);
    assert!(
        text.contains("fast-result"),
        "expected inlined result, got: {text}"
    );
    assert!(
        !text.contains("proc-"),
        "should not return process ID for fast command"
    );
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

// ── classify_bash_error ──────────────────────────────────────────

#[test]
fn classify_returns_none_on_success() {
    assert_eq!(classify_bash_error(Some(0), "", false), None);
    assert_eq!(classify_bash_error(Some(0), "some stdout", false), None);
}

#[test]
fn classify_timeout_wins_over_exit_code() {
    assert_eq!(
        classify_bash_error(Some(124), "Permission denied", true),
        Some("timeout")
    );
    assert_eq!(classify_bash_error(None, "", true), Some("timeout"));
}

#[test]
fn classify_permission_denied_from_stderr() {
    assert_eq!(
        classify_bash_error(Some(1), "bash: /root/x: Permission denied", false),
        Some("permission_denied")
    );
    assert_eq!(
        classify_bash_error(Some(13), "EACCES: permission denied", false),
        Some("permission_denied")
    );
    // Case insensitive
    assert_eq!(
        classify_bash_error(Some(1), "PERMISSION DENIED", false),
        Some("permission_denied")
    );
}

#[test]
fn classify_unknown_failure_returns_none() {
    assert_eq!(
        classify_bash_error(Some(2), "command not found", false),
        None
    );
}

#[test]
fn classify_ignores_permission_text_on_successful_exit() {
    // Success with permission text in output shouldn't classify as permission_denied.
    assert_eq!(
        classify_bash_error(Some(0), "Permission denied (ignored)", false),
        None
    );
}

// ── Tool details carry structured error metadata ──────────────────────────────

#[tokio::test]
async fn details_include_timed_out_and_error_class_on_timeout() {
    let tool = BashTool::new(Arc::new(MockRunner::with_timeout()), None);
    // Use stdin to force the direct-run path (not managed execution).
    let r = tool
        .execute(json!({"command": "sleep 10", "stdin": ""}), &make_ctx())
        .await
        .unwrap();
    let details = r.details.as_ref().expect("details present");
    assert_eq!(details["timedOut"], true);
    assert_eq!(details["errorClass"], "timeout");
    assert_eq!(details["exitCode"], 124);
}

#[tokio::test]
async fn details_include_permission_denied_error_class() {
    // Runner that emits permission-denied stderr
    struct PermDenyRunner;
    #[async_trait]
    impl ProcessRunner for PermDenyRunner {
        async fn run_command(
            &self,
            _command: &str,
            _opts: &ProcessOptions,
        ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
            Ok(crate::tools::traits::ProcessOutput {
                stdout: String::new(),
                stderr: "bash: /root/secret: Permission denied".into(),
                exit_code: 1,
                duration_ms: 5,
                timed_out: false,
                interrupted: false,
            })
        }
    }
    let tool = BashTool::new(Arc::new(PermDenyRunner), None);
    let r = tool
        .execute(
            json!({"command": "cat /root/secret", "stdin": ""}),
            &make_ctx(),
        )
        .await
        .unwrap();
    let details = r.details.as_ref().expect("details present");
    assert_eq!(details["errorClass"], "permission_denied");
    assert_eq!(details["timedOut"], false);
    assert_eq!(r.is_error, Some(true));
}

#[tokio::test]
async fn details_no_error_class_on_success() {
    let tool = BashTool::new(Arc::new(MockRunner::ok("hello")), None);
    let r = tool
        .execute(json!({"command": "echo hi", "stdin": ""}), &make_ctx())
        .await
        .unwrap();
    let details = r.details.as_ref().expect("details present");
    assert!(details.get("errorClass").is_none());
    assert_eq!(details["timedOut"], false);
}

#[tokio::test]
async fn dangerous_command_details_carry_blocked_error_class() {
    let tool = BashTool::new(Arc::new(MockRunner::ok("ok")), None);
    let r = tool
        .execute(json!({"command": "rm -rf /"}), &make_ctx())
        .await
        .unwrap();
    assert_eq!(r.is_error, Some(true));
    let details = r.details.as_ref().expect("blocked result has details");
    assert_eq!(details["errorClass"], "blocked");
}

#[tokio::test]
async fn backgrounded_details_carry_backgrounded_flag() {
    // Spawn a runner whose task never completes before the blocking timeout.
    // We use a very short blocking timeout so spawn_managed backgrounds it.
    struct SlowRunner;
    #[async_trait]
    impl ProcessRunner for SlowRunner {
        async fn run_command(
            &self,
            _command: &str,
            _opts: &ProcessOptions,
        ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            Ok(crate::tools::traits::ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 60_000,
                timed_out: false,
                interrupted: false,
            })
        }
    }
    let tool = BashTool::new(Arc::new(SlowRunner), None);
    let mut ctx = make_ctx();
    let pm = Arc::new(crate::runtime::orchestrator::process_manager::ProcessManager::new());
    ctx.process_manager = Some(pm);

    let r = tool
        .execute(json!({"command": "sleep 60", "timeout": 50_u64}), &ctx)
        .await
        .unwrap();
    let details = r.details.as_ref().expect("details present");
    assert_eq!(details["backgrounded"], true);
    assert!(details.get("processId").is_some());
}

// ── Progress event tests ──

#[test]
fn last_stdout_line_picks_trimmed_last_nonempty() {
    let chunk = "first line\nsecond line\n\n   ";
    assert_eq!(last_stdout_line_for_progress(chunk), "second line");
}

#[test]
fn last_stdout_line_truncates_with_ellipsis() {
    let chunk = "x".repeat(500);
    let out = last_stdout_line_for_progress(&chunk);
    assert!(out.ends_with('…'));
    assert!(out.chars().count() <= 201);
}

#[test]
fn last_stdout_line_falls_back_to_raw_trim_when_all_empty() {
    let chunk = "\n\n   \n";
    assert_eq!(last_stdout_line_for_progress(chunk), "");
}

#[test]
fn progress_throttle_emits_first_chunk_immediately() {
    let mut throttle = ProgressThrottle::default();
    let t0 = std::time::Instant::now();
    assert!(throttle.ready(t0), "first call must be ready");
}

#[test]
fn progress_throttle_blocks_within_1_second_window() {
    let mut throttle = ProgressThrottle::default();
    let t0 = std::time::Instant::now();
    assert!(throttle.ready(t0));
    assert!(!throttle.ready(t0 + std::time::Duration::from_millis(100)));
    assert!(!throttle.ready(t0 + std::time::Duration::from_millis(500)));
    assert!(!throttle.ready(t0 + std::time::Duration::from_millis(999)));
}

#[test]
fn progress_throttle_opens_after_1_second() {
    let mut throttle = ProgressThrottle::default();
    let t0 = std::time::Instant::now();
    assert!(throttle.ready(t0));
    assert!(throttle.ready(t0 + std::time::Duration::from_millis(1_000)));
    assert!(!throttle.ready(t0 + std::time::Duration::from_millis(1_500)));
    assert!(throttle.ready(t0 + std::time::Duration::from_millis(2_001)));
}

/// Streams chunks to the caller's `output_tx` over a controlled interval so the
/// forwarder task sees real message volume without spawning a real shell.
struct StreamingRunner {
    chunks: Vec<String>,
    delay_ms: u64,
}

#[async_trait::async_trait]
impl ProcessRunner for StreamingRunner {
    async fn run_command(
        &self,
        _command: &str,
        opts: &ProcessOptions,
    ) -> Result<crate::tools::traits::ProcessOutput, ToolError> {
        if let Some(tx) = opts.output_tx.as_ref() {
            for chunk in &self.chunks {
                let _ = tx.send(chunk.clone());
                tokio::time::sleep(std::time::Duration::from_millis(self.delay_ms)).await;
            }
        }
        Ok(crate::tools::traits::ProcessOutput {
            stdout: self.chunks.join(""),
            stderr: String::new(),
            exit_code: 0,
            duration_ms: self.chunks.len() as u64 * self.delay_ms,
            timed_out: false,
            interrupted: false,
        })
    }
}

#[tokio::test]
async fn bash_forwarder_rate_limits_progress_events() {
    // 5 chunks at 150ms intervals = 750ms total, below the 1s throttle window.
    // Exactly one progress event should be persisted.
    let runner = StreamingRunner {
        chunks: vec![
            "line 1\n".into(),
            "line 2\n".into(),
            "line 3\n".into(),
            "line 4\n".into(),
            "line 5\n".into(),
        ],
        delay_ms: 150,
    };
    let tool = BashTool::new(Arc::new(runner), None);
    let (mut ctx, store, session_id) = crate::tools::testutil::make_ctx_with_persister().await;
    ctx.process_manager = Some(Arc::new(
        crate::runtime::orchestrator::process_manager::ProcessManager::new(),
    ));

    let _ = tool
        .execute(json!({"command": "seq 1 5", "timeout": 10_000_u64}), &ctx)
        .await
        .unwrap();

    let events = crate::tools::testutil::drain_progress_events(&store, &session_id).await;
    assert_eq!(
        events.len(),
        1,
        "sub-1s chunk burst should emit exactly one throttled progress event"
    );
    assert_eq!(events[0]["toolCallId"], "call-1");
    assert!(
        events[0]["message"].as_str().unwrap_or("").contains("line"),
        "progress message should reflect stdout content: {events:?}"
    );
    assert_eq!(events[0]["turn"], 0);
}

#[tokio::test]
async fn bash_forwarder_no_progress_when_persister_absent() {
    // Default ctx has event_persister: None.
    let runner = StreamingRunner {
        chunks: vec!["hello\n".into()],
        delay_ms: 10,
    };
    let tool = BashTool::new(Arc::new(runner), None);
    let mut ctx = make_ctx();
    ctx.process_manager = Some(Arc::new(
        crate::runtime::orchestrator::process_manager::ProcessManager::new(),
    ));

    let r = tool
        .execute(json!({"command": "echo hello", "timeout": 5_000_u64}), &ctx)
        .await
        .unwrap();
    // Command runs normally; no panic from missing persister.
    assert!(r.is_error.is_none());
}
