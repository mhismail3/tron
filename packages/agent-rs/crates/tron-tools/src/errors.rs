//! Tool error types.
//!
//! Unified error enum for all tool execution failures. Each variant maps to
//! a specific user-facing error message format.

use std::io;

use thiserror::Error;

/// Errors that can occur during tool execution.
#[derive(Debug, Error)]
pub enum ToolError {
    /// Parameter validation failed.
    #[error("validation error: {message}")]
    Validation {
        /// Description of the validation failure.
        message: String,
    },

    /// File or path not found.
    #[error("file not found: {path}")]
    FileNotFound {
        /// The path that was not found.
        path: String,
    },

    /// Permission denied accessing a path.
    #[error("permission denied: {path}")]
    PermissionDenied {
        /// The path with insufficient permissions.
        path: String,
    },

    /// Path is a directory when a file was expected.
    #[error("is a directory: {path}")]
    IsDirectory {
        /// The directory path.
        path: String,
    },

    /// Path is not a directory when one was expected.
    #[error("not a directory: {path}")]
    NotDirectory {
        /// The non-directory path.
        path: String,
    },

    /// Generic I/O error.
    #[error("io error: {0}")]
    Io(#[from] io::Error),

    /// Operation timed out.
    #[error("timeout after {timeout_ms}ms")]
    Timeout {
        /// The timeout duration in milliseconds.
        timeout_ms: u64,
    },

    /// Operation was cancelled.
    #[error("cancelled")]
    Cancelled,

    /// Subprocess exited with a non-zero code.
    #[error("process exited with code {exit_code}: {message}")]
    ProcessFailed {
        /// The exit code.
        exit_code: i32,
        /// Description of the failure.
        message: String,
    },

    /// Command blocked by dangerous pattern detection.
    #[error("dangerous command blocked: {reason}")]
    DangerousCommand {
        /// Why the command was blocked.
        reason: String,
    },

    /// Resource not found.
    #[error("not found: {message}")]
    NotFound {
        /// Description of what was not found.
        message: String,
    },

    /// HTTP request error.
    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON serialization/deserialization error.
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    /// Tool not found in registry.
    #[error("tool not found: {name}")]
    ToolNotFound {
        /// The tool name that was not found.
        name: String,
    },

    /// Internal error (catch-all).
    #[error("{message}")]
    Internal {
        /// Description of the internal error.
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_display() {
        let err = ToolError::Validation {
            message: "missing required parameter".into(),
        };
        assert_eq!(
            err.to_string(),
            "validation error: missing required parameter"
        );
    }

    #[test]
    fn file_not_found_display_includes_path() {
        let err = ToolError::FileNotFound {
            path: "/tmp/missing.txt".into(),
        };
        assert_eq!(err.to_string(), "file not found: /tmp/missing.txt");
    }

    #[test]
    fn timeout_display_includes_ms() {
        let err = ToolError::Timeout { timeout_ms: 5000 };
        assert_eq!(err.to_string(), "timeout after 5000ms");
    }

    #[test]
    fn from_io_error() {
        let io_err = io::Error::new(io::ErrorKind::NotFound, "gone");
        let tool_err = ToolError::from(io_err);
        assert!(matches!(tool_err, ToolError::Io(_)));
        assert!(tool_err.to_string().contains("gone"));
    }

    #[test]
    fn from_serde_json_error() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalid").unwrap_err();
        let tool_err = ToolError::from(json_err);
        assert!(matches!(tool_err, ToolError::Json(_)));
    }
}
