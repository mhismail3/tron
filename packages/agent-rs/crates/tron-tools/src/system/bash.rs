//! `Bash` tool — shell command execution with timeout and danger detection.
//!
//! Spawns `bash -c <command>` in the working directory. Detects dangerous
//! patterns (rm -rf /, fork bombs, dd to device, etc.) and blocks them.
//! Output is truncated if it exceeds the character budget.

use std::sync::Arc;

use async_trait::async_trait;
use regex::Regex;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{ProcessOptions, ProcessRunner, ToolContext, TronTool};
use crate::utils::truncation::estimate_tokens;
use crate::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MAX_TIMEOUT_MS: u64 = 600_000;
const MAX_OUTPUT_CHARS: usize = 400_000;

/// The `Bash` tool executes shell commands.
pub struct BashTool {
    runner: Arc<dyn ProcessRunner>,
    danger_patterns: Vec<Regex>,
}

impl BashTool {
    /// Create a new `Bash` tool with the given process runner.
    pub fn new(runner: Arc<dyn ProcessRunner>) -> Self {
        Self {
            runner,
            danger_patterns: compile_danger_patterns(),
        }
    }

    fn check_dangerous(&self, command: &str) -> Option<String> {
        for pattern in &self.danger_patterns {
            if pattern.is_match(command) {
                return Some("Potentially destructive command pattern detected".into());
            }
        }
        None
    }
}

fn compile_danger_patterns() -> Vec<Regex> {
    let patterns = [
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/($|\s|;|\|)",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/\*",
        r"rm\s+(-[^\s]*\s+)*-[^\s]*[rR][^\s]*\s+/(usr|etc|var|home|boot|dev|proc|sys)\b",
        r":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:",
        r"dd\s+.*of=/dev/[sh]d",
        r"mkfs\.\w+\s+/dev/",
        r"chmod\s+(-[^\s]+\s+)*777\s+/$",
        r">\s*/dev/[sh]d",
    ];
    patterns
        .iter()
        .filter_map(|p| Regex::new(p).ok())
        .collect()
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
        Tool {
            name: "Bash".into(),
            description: "Execute a shell command.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("command".into(), json!({"type": "string", "description": "The shell command to execute"}));
                    let _ = m.insert("timeout".into(), json!({"type": "number", "description": "Timeout in milliseconds (max 600000)"}));
                    let _ = m.insert("description".into(), json!({"type": "string", "description": "Brief description of what the command does"}));
                    m
                }),
                required: Some(vec!["command".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let command = match validate_required_string(&params, "command", "the shell command") {
            Ok(c) => c,
            Err(e) => return Ok(e),
        };

        // Check dangerous patterns
        if let Some(reason) = self.check_dangerous(&command) {
            return Ok(error_result(reason));
        }

        let timeout_ms = get_optional_u64(&params, "timeout")
            .unwrap_or(DEFAULT_TIMEOUT_MS)
            .min(MAX_TIMEOUT_MS);
        let description = get_optional_string(&params, "description");

        let opts = ProcessOptions {
            working_directory: ctx.working_directory.clone(),
            timeout_ms,
            cancellation: ctx.cancellation.clone(),
            env: std::collections::HashMap::new(),
        };

        let output = self.runner.run_command(&command, &opts).await?;

        // Combine stdout + stderr
        let mut combined = output.stdout;
        if !output.stderr.is_empty() {
            if !combined.is_empty() {
                combined.push('\n');
            }
            combined.push_str(&output.stderr);
        }

        // Truncate if needed
        let original_chars = combined.len();
        let truncated = original_chars > MAX_OUTPUT_CHARS;
        if truncated {
            combined.truncate(MAX_OUTPUT_CHARS);
            combined.push_str("\n... [output truncated]");
        }

        let is_error = if output.exit_code != 0 { Some(true) } else { None };

        let details = json!({
            "command": command,
            "exitCode": output.exit_code,
            "durationMs": output.duration_ms,
            "truncated": truncated,
            "originalChars": original_chars,
            "originalTokens": estimate_tokens(original_chars),
            "finalTokens": estimate_tokens(combined.len()),
            "interrupted": output.interrupted,
            "description": description,
        });

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(combined),
            ]),
            details: Some(details),
            is_error,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> crate::traits::ProcessOutput + Send + Sync>,
    }

    impl MockRunner {
        fn ok(stdout: &str) -> Self {
            let s = stdout.to_owned();
            Self { handler: Box::new(move |_| crate::traits::ProcessOutput {
                stdout: s.clone(), stderr: String::new(), exit_code: 0,
                duration_ms: 10, timed_out: false, interrupted: false,
            })}
        }

        fn with_exit(stdout: &str, exit_code: i32) -> Self {
            let s = stdout.to_owned();
            Self { handler: Box::new(move |_| crate::traits::ProcessOutput {
                stdout: s.clone(), stderr: String::new(), exit_code,
                duration_ms: 10, timed_out: false, interrupted: false,
            })}
        }

        fn with_timeout() -> Self {
            Self { handler: Box::new(|_| crate::traits::ProcessOutput {
                stdout: String::new(), stderr: String::new(), exit_code: 124,
                duration_ms: 120_000, timed_out: true, interrupted: false,
            })}
        }

        fn with_interrupt() -> Self {
            Self { handler: Box::new(|_| crate::traits::ProcessOutput {
                stdout: "partial output".into(), stderr: String::new(), exit_code: 130,
                duration_ms: 50, timed_out: false, interrupted: true,
            })}
        }

        fn large_output() -> Self {
            Self { handler: Box::new(|_| crate::traits::ProcessOutput {
                stdout: "x".repeat(500_000), stderr: String::new(), exit_code: 0,
                duration_ms: 10, timed_out: false, interrupted: false,
            })}
        }
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(&self, command: &str, _opts: &ProcessOptions) -> Result<crate::traits::ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks.iter().filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                _ => None,
            }).collect::<Vec<_>>().join(""),
        }
    }

    #[tokio::test]
    async fn simple_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("hello world")));
        let r = tool.execute(json!({"command": "echo hello"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert!(extract_text(&r).contains("hello world"));
    }

    #[tokio::test]
    async fn nonzero_exit_code() {
        let tool = BashTool::new(Arc::new(MockRunner::with_exit("error output", 1)));
        let r = tool.execute(json!({"command": "false"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert_eq!(r.details.unwrap()["exitCode"], 1);
    }

    #[tokio::test]
    async fn timeout_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_timeout()));
        let r = tool.execute(json!({"command": "sleep 999"}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["durationMs"], 120_000);
    }

    #[tokio::test]
    async fn timeout_capped_at_max() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        // Even with very large timeout, the options cap at MAX_TIMEOUT_MS
        let r = tool.execute(json!({"command": "ls", "timeout": 999_999_999}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn default_timeout_when_not_specified() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "ls"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn output_truncation() {
        let tool = BashTool::new(Arc::new(MockRunner::large_output()));
        let r = tool.execute(json!({"command": "cat bigfile"}), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("[output truncated]"));
        assert!(r.details.unwrap()["truncated"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn missing_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn empty_command() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": ""}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn cancellation_handling() {
        let tool = BashTool::new(Arc::new(MockRunner::with_interrupt()));
        let r = tool.execute(json!({"command": "long-running"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert!(d["interrupted"].as_bool().unwrap());
        assert_eq!(d["exitCode"], 130);
    }

    #[tokio::test]
    async fn description_stored_in_details() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "ls", "description": "list files"}), &make_ctx()).await.unwrap();
        assert_eq!(r.details.unwrap()["description"], "list files");
    }

    #[tokio::test]
    async fn details_include_exit_code_and_duration() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("out")));
        let r = tool.execute(json!({"command": "echo"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["exitCode"], 0);
        assert!(d["durationMs"].as_u64().is_some());
    }

    // Dangerous pattern tests

    #[tokio::test]
    async fn blocks_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "rm -rf /"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("destructive"));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_rf_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "sudo rm -rf /"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_rm_rf_star() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "rm -rf /*"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_fork_bomb() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": ":(){ :|: & };:"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_dd_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "dd if=/dev/zero of=/dev/sda"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_mkfs() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "mkfs.ext4 /dev/sda"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_chmod_777_root() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "chmod 777 /"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_redirect_to_device() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "> /dev/sda"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn blocks_sudo_rm_usr() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("")));
        let r = tool.execute(json!({"command": "sudo rm -rf /usr"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn allows_safe_commands() {
        let tool = BashTool::new(Arc::new(MockRunner::ok("output")));
        for cmd in ["ls -la", "git status", "rm file.txt", "cat /etc/hosts"] {
            let r = tool.execute(json!({"command": cmd}), &make_ctx()).await.unwrap();
            assert!(r.is_error.is_none(), "Command incorrectly blocked: {cmd}");
        }
    }
}
