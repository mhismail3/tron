//! Runtime error types.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Errors that can occur during agent runtime execution.
#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    /// LLM provider error (streaming, auth, rate limit).
    #[error("Provider error: {0}")]
    Provider(#[from] tron_llm::provider::ProviderError),

    /// Tool execution error.
    #[error("Tool error: {tool_name}: {message}")]
    Tool {
        /// Tool name.
        tool_name: String,
        /// Error description.
        message: String,
    },

    /// Context management error (compaction, token limit).
    #[error("Context error: {0}")]
    Context(String),

    /// Operation was cancelled via abort/cancellation token.
    #[error("Operation cancelled")]
    Cancelled,

    /// Agent exceeded the maximum turn count.
    #[error("Max turns ({0}) exceeded")]
    MaxTurns(u32),

    /// Session not found.
    #[error("Session not found: {0}")]
    SessionNotFound(String),

    /// Session is busy (another prompt is running).
    #[error("Session busy: {0}")]
    SessionBusy(String),

    /// Event persistence error.
    #[error("Persistence error: {0}")]
    Persistence(String),

    /// Internal / unexpected error.
    #[error("Internal error: {0}")]
    Internal(String),
}

impl RuntimeError {
    /// Whether the error is recoverable (user can retry).
    pub fn is_recoverable(&self) -> bool {
        match self {
            Self::Provider(e) => e.is_retryable(),
            Self::Cancelled | Self::MaxTurns(_) | Self::SessionBusy(_) => true,
            Self::Tool { .. }
            | Self::Context(_)
            | Self::SessionNotFound(_)
            | Self::Persistence(_)
            | Self::Internal(_) => false,
        }
    }

    /// Error category string for event emission.
    pub fn category(&self) -> &str {
        match self {
            Self::Provider(_) => "provider",
            Self::Tool { .. } => "tool",
            Self::Context(_) => "context",
            Self::Cancelled => "cancelled",
            Self::MaxTurns(_) => "max_turns",
            Self::SessionNotFound(_) => "session_not_found",
            Self::SessionBusy(_) => "session_busy",
            Self::Persistence(_) => "persistence",
            Self::Internal(_) => "internal",
        }
    }
}

/// Reason the agent stopped running.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    /// LLM chose to stop (`end_turn`).
    EndTurn,
    /// Turn limit reached.
    MaxTurns,
    /// Tool requested stop (`AskUserQuestion`, `RenderAppUI`).
    ToolStop,
    /// Unrecoverable error.
    Error,
    /// User abort.
    Interrupted,
    /// Pure text response (no tools to execute).
    NoToolCalls,
}

impl fmt::Display for StopReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EndTurn => write!(f, "end_turn"),
            Self::MaxTurns => write!(f, "max_turns"),
            Self::ToolStop => write!(f, "tool_stop"),
            Self::Error => write!(f, "error"),
            Self::Interrupted => write!(f, "interrupted"),
            Self::NoToolCalls => write!(f, "no_tool_calls"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_error_display() {
        let err = RuntimeError::Tool {
            tool_name: "bash".into(),
            message: "command failed".into(),
        };
        assert_eq!(err.to_string(), "Tool error: bash: command failed");
    }

    #[test]
    fn runtime_error_cancelled_display() {
        let err = RuntimeError::Cancelled;
        assert_eq!(err.to_string(), "Operation cancelled");
    }

    #[test]
    fn runtime_error_max_turns() {
        let err = RuntimeError::MaxTurns(25);
        assert_eq!(err.to_string(), "Max turns (25) exceeded");
    }

    #[test]
    fn runtime_error_category() {
        assert_eq!(RuntimeError::Cancelled.category(), "cancelled");
        assert_eq!(RuntimeError::MaxTurns(5).category(), "max_turns");
        assert_eq!(RuntimeError::Context("x".into()).category(), "context");
        assert_eq!(RuntimeError::Internal("x".into()).category(), "internal");
        assert_eq!(
            RuntimeError::SessionNotFound("s".into()).category(),
            "session_not_found"
        );
        assert_eq!(
            RuntimeError::SessionBusy("s".into()).category(),
            "session_busy"
        );
        assert_eq!(
            RuntimeError::Persistence("p".into()).category(),
            "persistence"
        );
        assert_eq!(
            RuntimeError::Tool {
                tool_name: "t".into(),
                message: "m".into()
            }
            .category(),
            "tool"
        );
    }

    #[test]
    fn runtime_error_is_recoverable() {
        assert!(RuntimeError::Cancelled.is_recoverable());
        assert!(RuntimeError::MaxTurns(5).is_recoverable());
        assert!(RuntimeError::SessionBusy("s".into()).is_recoverable());
        assert!(!RuntimeError::Internal("x".into()).is_recoverable());
        assert!(!RuntimeError::Context("x".into()).is_recoverable());
        assert!(!RuntimeError::SessionNotFound("s".into()).is_recoverable());
    }

    #[test]
    fn stop_reason_serde_roundtrip() {
        let reasons = vec![
            StopReason::EndTurn,
            StopReason::MaxTurns,
            StopReason::ToolStop,
            StopReason::Error,
            StopReason::Interrupted,
            StopReason::NoToolCalls,
        ];
        for r in &reasons {
            let json = serde_json::to_string(r).unwrap();
            let back: StopReason = serde_json::from_str(&json).unwrap();
            assert_eq!(*r, back);
        }
    }

    #[test]
    fn stop_reason_json_values() {
        assert_eq!(
            serde_json::to_string(&StopReason::EndTurn).unwrap(),
            "\"end_turn\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::MaxTurns).unwrap(),
            "\"max_turns\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::ToolStop).unwrap(),
            "\"tool_stop\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::NoToolCalls).unwrap(),
            "\"no_tool_calls\""
        );
    }

    #[test]
    fn stop_reason_display() {
        assert_eq!(StopReason::EndTurn.to_string(), "end_turn");
        assert_eq!(StopReason::Interrupted.to_string(), "interrupted");
    }
}
