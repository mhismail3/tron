use async_trait::async_trait;
use std::time::{Duration, Instant};
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_OUTPUT_BYTES: usize = 1_000_000; // 1MB

/// Patterns that indicate potential command injection.
const BLOCKED_PATTERNS: &[&str] = &[
    "$(", // command substitution
    "${", // variable expansion with braces
];

pub struct BashTool {
    timeout: Duration,
}

impl BashTool {
    pub fn new() -> Self {
        Self {
            timeout: DEFAULT_TIMEOUT,
        }
    }

    pub fn with_timeout(timeout: Duration) -> Self {
        Self { timeout }
    }
}

impl Default for BashTool {
    fn default() -> Self {
        Self::new()
    }
}

/// Validate a command against the allowlist rules.
pub fn validate_command(command: &str) -> Result<(), String> {
    // Check for blocked patterns
    for pattern in BLOCKED_PATTERNS {
        if command.contains(pattern) {
            return Err(format!("Command contains blocked pattern: {pattern}"));
        }
    }

    // Check for backtick command substitution
    if command.contains('`') {
        return Err("Command contains backtick command substitution".into());
    }

    Ok(())
}

#[async_trait]
impl Tool for BashTool {
    fn name(&self) -> &str {
        "Bash"
    }

    fn description(&self) -> &str {
        "Execute a shell command"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["command"],
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in milliseconds (max 600000)"
                },
                "description": {
                    "type": "string",
                    "description": "Description of what this command does"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Sequential
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let command = args["command"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("command is required".into()))?;

        // Validate command safety
        validate_command(command).map_err(ToolError::InvalidArguments)?;

        let timeout = args["timeout"]
            .as_u64()
            .map(|ms| Duration::from_millis(ms.min(600_000)))
            .unwrap_or(self.timeout);

        let output = tokio::time::timeout(
            timeout,
            tokio::process::Command::new("bash")
                .arg("-c")
                .arg(command)
                .current_dir(&ctx.working_directory)
                .output(),
        )
        .await
        .map_err(|_| ToolError::Timeout(timeout))?
        .map_err(|e| ToolError::ExecutionFailed(format!("Failed to execute command: {e}")))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        let mut result_content = String::new();

        if !stdout.is_empty() {
            let truncated = if stdout.len() > MAX_OUTPUT_BYTES {
                format!(
                    "{}...\n[truncated: {} bytes total]",
                    &stdout[..MAX_OUTPUT_BYTES],
                    stdout.len()
                )
            } else {
                stdout.to_string()
            };
            result_content.push_str(&truncated);
        }

        if !stderr.is_empty() {
            if !result_content.is_empty() {
                result_content.push('\n');
            }
            let truncated = if stderr.len() > MAX_OUTPUT_BYTES {
                format!(
                    "STDERR:\n{}...\n[truncated]",
                    &stderr[..MAX_OUTPUT_BYTES]
                )
            } else {
                format!("STDERR:\n{stderr}")
            };
            result_content.push_str(&truncated);
        }

        if result_content.is_empty() {
            result_content = "(no output)".to_string();
        }

        let exit_code = output.status.code().unwrap_or(-1);
        let is_error = !output.status.success();

        if is_error {
            result_content = format!("Exit code: {exit_code}\n{result_content}");
        }

        Ok(ToolResult {
            content: result_content,
            is_error,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId};
    use tokio_util::sync::CancellationToken;

    fn test_ctx() -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: std::env::temp_dir(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[test]
    fn validate_clean_commands() {
        assert!(validate_command("ls -la").is_ok());
        assert!(validate_command("git status").is_ok());
        assert!(validate_command("echo hello").is_ok());
        assert!(validate_command("cat file.txt | grep pattern").is_ok());
        assert!(validate_command("ls && echo done").is_ok());
    }

    #[test]
    fn validate_blocked_commands() {
        assert!(validate_command("echo $(whoami)").is_err());
        assert!(validate_command("echo ${HOME}").is_err());
        assert!(validate_command("echo `whoami`").is_err());
    }

    #[tokio::test]
    async fn execute_simple_command() {
        let tool = BashTool::new();
        let result = tool
            .execute(serde_json::json!({"command": "echo hello world"}), &test_ctx())
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("hello world"));
    }

    #[tokio::test]
    async fn execute_failing_command() {
        let tool = BashTool::new();
        let result = tool
            .execute(serde_json::json!({"command": "false"}), &test_ctx())
            .await
            .unwrap();

        assert!(result.is_error);
        assert!(result.content.contains("Exit code: 1"));
    }

    #[tokio::test]
    async fn execute_with_stderr() {
        let tool = BashTool::new();
        let result = tool
            .execute(
                serde_json::json!({"command": "echo error >&2"}),
                &test_ctx(),
            )
            .await
            .unwrap();

        assert!(result.content.contains("STDERR"));
        assert!(result.content.contains("error"));
    }

    #[tokio::test]
    async fn execute_blocked_command() {
        let tool = BashTool::new();
        let result = tool
            .execute(
                serde_json::json!({"command": "echo $(whoami)"}),
                &test_ctx(),
            )
            .await;

        assert!(result.is_err());
    }

    #[tokio::test]
    async fn execute_timeout() {
        let tool = BashTool::with_timeout(Duration::from_millis(100));
        let result = tool
            .execute(
                serde_json::json!({"command": "sleep 10"}),
                &test_ctx(),
            )
            .await;

        assert!(result.is_err());
        assert!(matches!(result.unwrap_err(), ToolError::Timeout(_)));
    }
}
