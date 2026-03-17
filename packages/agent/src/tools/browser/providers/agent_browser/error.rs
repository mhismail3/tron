//! Error types for the agent-browser provider.

use crate::tools::errors::ToolError;

/// Errors specific to the agent-browser provider.
#[derive(Debug, thiserror::Error)]
pub enum AgentBrowserError {
    /// agent-browser binary not found on PATH.
    #[error("agent-browser not found on PATH — install with: brew install agent-browser")]
    NotInstalled,

    /// CLI command returned non-zero exit code.
    #[error("agent-browser command failed (exit {exit_code}): {stderr}")]
    CommandFailed {
        /// Process exit code.
        exit_code: i32,
        /// Stderr output.
        stderr: String,
    },

    /// CLI command timed out.
    #[error("agent-browser command timed out after {timeout_ms}ms")]
    Timeout {
        /// Timeout duration.
        timeout_ms: u64,
    },

    /// Failed to parse CLI output.
    #[error("failed to parse agent-browser output: {context}")]
    ParseError {
        /// Context about the parse failure.
        context: String,
    },

    /// WebSocket stream connection failed.
    #[error("stream connection failed: {0}")]
    StreamError(String),

    /// Failed to spawn agent-browser process.
    #[error("agent-browser process failed to spawn: {0}")]
    SpawnError(String),

    /// Screenshot temp file not found after command.
    #[error("screenshot file not found: {path}")]
    ScreenshotNotFound {
        /// Expected file path.
        path: String,
    },

    /// Screenshot file read failed.
    #[error("screenshot file read failed: {0}")]
    ScreenshotReadFailed(std::io::Error),
}

impl From<AgentBrowserError> for ToolError {
    fn from(e: AgentBrowserError) -> Self {
        ToolError::Internal {
            message: e.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn not_installed_converts_to_tool_error() {
        let e: ToolError = AgentBrowserError::NotInstalled.into();
        match e {
            ToolError::Internal { message } => assert!(message.contains("not found")),
            other => panic!("expected Internal, got: {other:?}"),
        }
    }

    #[test]
    fn command_failed_preserves_stderr() {
        let e: ToolError = AgentBrowserError::CommandFailed {
            exit_code: 1,
            stderr: "element not found".into(),
        }
        .into();
        match e {
            ToolError::Internal { message } => {
                assert!(message.contains("exit 1"));
                assert!(message.contains("element not found"));
            }
            other => panic!("expected Internal, got: {other:?}"),
        }
    }

    #[test]
    fn timeout_preserves_duration() {
        let e: ToolError = AgentBrowserError::Timeout { timeout_ms: 30000 }.into();
        match e {
            ToolError::Internal { message } => assert!(message.contains("30000")),
            other => panic!("expected Internal, got: {other:?}"),
        }
    }

    #[test]
    fn parse_error_preserves_context() {
        let e: ToolError = AgentBrowserError::ParseError {
            context: "invalid JSON at line 1".into(),
        }
        .into();
        match e {
            ToolError::Internal { message } => assert!(message.contains("invalid JSON")),
            other => panic!("expected Internal, got: {other:?}"),
        }
    }

    #[test]
    fn screenshot_not_found_preserves_path() {
        let e: ToolError = AgentBrowserError::ScreenshotNotFound {
            path: "/tmp/test.png".into(),
        }
        .into();
        match e {
            ToolError::Internal { message } => assert!(message.contains("/tmp/test.png")),
            other => panic!("expected Internal, got: {other:?}"),
        }
    }
}
