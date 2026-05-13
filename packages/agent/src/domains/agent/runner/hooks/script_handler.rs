//! Script-based hook handler.
//!
//! Executes external scripts (`.sh`, `.js`, `.ts`) as hook handlers.
//! Scripts receive [`HookContext`] as JSON on stdin and return
//! [`HookResult`] as JSON on stdout. Fail-open on all error paths.

use std::path::PathBuf;

use async_trait::async_trait;
use tracing::warn;

use super::errors::HookError;
use super::handler::HookHandler;
use super::types::{HookContext, HookExecutionMode, HookResult, HookType};

/// Maximum bytes to read from script stdout.
const MAX_STDOUT_BYTES: usize = 64 * 1024; // 64KB

/// Script-based hook handler.
///
/// Spawns an external process, pipes the [`HookContext`] as JSON to stdin,
/// and parses the stdout as a [`HookResult`]. All error paths (timeout,
/// non-zero exit, parse failure, missing file, permission denied) fail
/// open with `Continue`.
pub struct ScriptHookHandler {
    name: String,
    hook_type: HookType,
    script_path: PathBuf,
    priority: i32,
    timeout_ms: u64,
}

impl ScriptHookHandler {
    /// Create a new script hook handler.
    pub fn new(
        name: String,
        hook_type: HookType,
        script_path: PathBuf,
        priority: i32,
        timeout_ms: u64,
    ) -> Self {
        Self {
            name,
            hook_type,
            script_path,
            priority,
            timeout_ms,
        }
    }
}

#[async_trait]
impl HookHandler for ScriptHookHandler {
    fn name(&self) -> &str {
        &self.name
    }

    fn hook_type(&self) -> HookType {
        self.hook_type
    }

    fn priority(&self) -> i32 {
        self.priority
    }

    fn execution_mode(&self) -> HookExecutionMode {
        HookExecutionMode::Background
    }

    fn timeout_ms(&self) -> Option<u64> {
        Some(self.timeout_ms)
    }

    fn description(&self) -> Option<&str> {
        None
    }

    async fn handle(&self, context: &HookContext) -> Result<HookResult, HookError> {
        use tokio::io::AsyncWriteExt;

        let context_json = serde_json::to_string(context)
            .map_err(|e| HookError::Internal(format!("Failed to serialize hook context: {e}")))?;

        // Determine the command to run based on file extension
        let (cmd, args) = resolve_command(&self.script_path);

        let mut child = tokio::process::Command::new(&cmd)
            .args(&args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| {
                warn!(
                    name = %self.name,
                    path = %self.script_path.display(),
                    error = %e,
                    "Failed to spawn script hook (fail-open)"
                );
                HookError::HandlerError {
                    name: self.name.clone(),
                    message: format!("Failed to spawn script: {e}"),
                }
            })?;

        // Write context to stdin
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(context_json.as_bytes()).await;
            let _ = stdin.shutdown().await;
        }

        // Wait for completion
        let output = child
            .wait_with_output()
            .await
            .map_err(|e| HookError::HandlerError {
                name: self.name.clone(),
                message: format!("Failed to wait for script: {e}"),
            })?;

        // Log stderr if present
        if !output.stderr.is_empty() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            warn!(
                name = %self.name,
                stderr = %stderr,
                "Script hook stderr output"
            );
        }

        // Non-zero exit → fail-open
        if !output.status.success() {
            return Err(HookError::HandlerError {
                name: self.name.clone(),
                message: format!(
                    "Script exited with status {}",
                    output.status.code().unwrap_or(-1)
                ),
            });
        }

        // Truncate stdout
        let stdout_bytes = if output.stdout.len() > MAX_STDOUT_BYTES {
            &output.stdout[..MAX_STDOUT_BYTES]
        } else {
            &output.stdout
        };

        let stdout = String::from_utf8_lossy(stdout_bytes);
        let stdout = stdout.trim();

        // Empty stdout → fail-open
        if stdout.is_empty() {
            return Err(HookError::HandlerError {
                name: self.name.clone(),
                message: "Script produced no output".to_string(),
            });
        }

        // Parse as HookResult JSON
        serde_json::from_str::<HookResult>(stdout).map_err(|e| HookError::HandlerError {
            name: self.name.clone(),
            message: format!("Failed to parse script output as JSON: {e}"),
        })
    }
}

/// Determine the command and args to run for a script file.
fn resolve_command(path: &PathBuf) -> (String, Vec<String>) {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");

    let path_str = path.to_string_lossy().to_string();

    match ext {
        "js" | "mjs" => ("node".to_string(), vec![path_str]),
        "ts" => ("npx".to_string(), vec!["tsx".to_string(), path_str]),
        _ => (path_str, vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    struct TestScript {
        _dir: TempDir,
        path: PathBuf,
    }

    fn make_session_start_context() -> HookContext {
        HookContext::SessionStart {
            session_id: "test-session-123".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            working_directory: "/tmp/test-project".to_string(),
        }
    }

    fn create_script(content: &str) -> TestScript {
        create_script_with_mode(content, 0o755)
    }

    fn create_script_with_mode(content: &str, mode: u32) -> TestScript {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("hook.sh");
        std::fs::write(&path, content).unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(mode);
            std::fs::set_permissions(&path, perms).unwrap();
        }

        TestScript { _dir: dir, path }
    }

    fn make_handler(script: &TestScript, hook_type: HookType) -> ScriptHookHandler {
        ScriptHookHandler::new(
            "test-hook".to_string(),
            hook_type,
            script.path.clone(),
            0,
            5000,
        )
    }

    // --- Happy path tests ---

    #[tokio::test]
    async fn test_execute_shell_script_returns_continue() {
        let script = create_script("#!/bin/bash\necho '{\"action\":\"continue\"}'");
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await.unwrap();
        assert_eq!(result.action, super::super::types::HookAction::Continue);
    }

    #[tokio::test]
    async fn test_execute_shell_script_returns_block_with_reason() {
        let script = create_script(
            "#!/bin/bash\necho '{\"action\":\"block\",\"reason\":\"policy violation\"}'",
        );
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await.unwrap();
        assert!(result.is_blocked());
        assert_eq!(result.reason.as_deref(), Some("policy violation"));
    }

    #[tokio::test]
    async fn test_execute_shell_script_returns_modify_with_modifications() {
        let script = create_script(
            "#!/bin/bash\necho '{\"action\":\"modify\",\"modifications\":{\"key\":\"value\"}}'",
        );
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await.unwrap();
        assert_eq!(result.action, super::super::types::HookAction::Modify);
        assert_eq!(result.modifications.unwrap()["key"], "value");
    }

    #[tokio::test]
    async fn test_script_receives_context_on_stdin() {
        let script = create_script(
            r#"#!/bin/bash
CONTEXT=$(cat)
SESSION_ID=$(echo "$CONTEXT" | python3 -c "import sys,json; print(json.load(sys.stdin)['sessionId'])")
echo "{\"action\":\"continue\",\"message\":\"session=$SESSION_ID\"}"
"#,
        );
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await.unwrap();
        assert!(
            result
                .message
                .as_deref()
                .unwrap()
                .contains("test-session-123"),
            "Expected message to contain session ID, got: {:?}",
            result.message
        );
    }

    // --- Error path tests (fail-open) ---

    #[tokio::test]
    async fn test_script_exit_nonzero_returns_error() {
        let script = create_script("#!/bin/bash\nexit 1");
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Non-zero exit should return error");
    }

    #[tokio::test]
    async fn test_script_empty_stdout_returns_error() {
        let script = create_script("#!/bin/bash\n# no output");
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Empty stdout should return error");
    }

    #[tokio::test]
    async fn test_script_malformed_json_returns_error() {
        let script = create_script("#!/bin/bash\necho 'not json at all'");
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Malformed JSON should return error");
    }

    #[tokio::test]
    async fn test_script_partial_json_returns_error() {
        let script = create_script("#!/bin/bash\necho '{\"action\":\"continue\"'");
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Partial JSON should return error");
    }

    #[tokio::test]
    async fn test_script_stderr_does_not_affect_result() {
        let script = create_script(
            "#!/bin/bash\necho 'debug info' >&2\necho '{\"action\":\"continue\",\"message\":\"ok\"}'",
        );
        let handler = make_handler(&script, HookType::SessionStart);
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await.unwrap();
        assert_eq!(result.action, super::super::types::HookAction::Continue);
        assert_eq!(result.message.as_deref(), Some("ok"));
    }

    #[tokio::test]
    async fn test_script_not_found_returns_error() {
        let handler = ScriptHookHandler::new(
            "missing".to_string(),
            HookType::SessionStart,
            PathBuf::from("/nonexistent/hook.sh"),
            0,
            5000,
        );
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Missing script should return error");
    }

    #[tokio::test]
    #[cfg(unix)]
    async fn test_script_not_executable_returns_error() {
        let script =
            create_script_with_mode("#!/bin/bash\necho '{\"action\":\"continue\"}'", 0o644);

        let handler = ScriptHookHandler::new(
            "no-exec".to_string(),
            HookType::SessionStart,
            script.path.clone(),
            0,
            5000,
        );
        let ctx = make_session_start_context();

        let result = handler.handle(&ctx).await;
        assert!(result.is_err(), "Non-executable script should return error");
    }

    // --- Trait implementation tests ---

    #[test]
    fn test_execution_mode_is_background() {
        let handler = ScriptHookHandler::new(
            "test".to_string(),
            HookType::SessionStart,
            PathBuf::from("/tmp/test.sh"),
            0,
            5000,
        );
        assert_eq!(handler.execution_mode(), HookExecutionMode::Background);
    }

    #[test]
    fn test_should_handle_always_true() {
        let handler = ScriptHookHandler::new(
            "test".to_string(),
            HookType::SessionStart,
            PathBuf::from("/tmp/test.sh"),
            0,
            5000,
        );
        let ctx = make_session_start_context();
        assert!(handler.should_handle(&ctx));
    }

    #[test]
    fn test_priority_returns_configured_value() {
        let handler = ScriptHookHandler::new(
            "test".to_string(),
            HookType::SessionStart,
            PathBuf::from("/tmp/test.sh"),
            42,
            5000,
        );
        assert_eq!(handler.priority(), 42);
    }

    #[test]
    fn test_timeout_ms_returns_configured_value() {
        let handler = ScriptHookHandler::new(
            "test".to_string(),
            HookType::SessionStart,
            PathBuf::from("/tmp/test.sh"),
            0,
            3000,
        );
        assert_eq!(handler.timeout_ms(), Some(3000));
    }

    #[test]
    fn test_hook_type_returns_configured_value() {
        let handler = ScriptHookHandler::new(
            "test".to_string(),
            HookType::PostCapabilityInvocation,
            PathBuf::from("/tmp/test.sh"),
            0,
            5000,
        );
        assert_eq!(handler.hook_type(), HookType::PostCapabilityInvocation);
    }

    // --- resolve_command tests ---

    #[test]
    fn test_resolve_command_shell_script() {
        let path = PathBuf::from("/tmp/hook.sh");
        let (cmd, args) = resolve_command(&path);
        assert_eq!(cmd, "/tmp/hook.sh");
        assert!(args.is_empty());
    }

    #[test]
    fn test_resolve_command_js_file() {
        let path = PathBuf::from("/tmp/hook.js");
        let (cmd, args) = resolve_command(&path);
        assert_eq!(cmd, "node");
        assert_eq!(args, vec!["/tmp/hook.js"]);
    }

    #[test]
    fn test_resolve_command_mjs_file() {
        let path = PathBuf::from("/tmp/hook.mjs");
        let (cmd, args) = resolve_command(&path);
        assert_eq!(cmd, "node");
        assert_eq!(args, vec!["/tmp/hook.mjs"]);
    }

    #[test]
    fn test_resolve_command_ts_file() {
        let path = PathBuf::from("/tmp/hook.ts");
        let (cmd, args) = resolve_command(&path);
        assert_eq!(cmd, "npx");
        assert_eq!(args, vec!["tsx", "/tmp/hook.ts"]);
    }

    #[test]
    fn test_resolve_command_no_extension() {
        let path = PathBuf::from("/tmp/hook");
        let (cmd, args) = resolve_command(&path);
        assert_eq!(cmd, "/tmp/hook");
        assert!(args.is_empty());
    }
}
