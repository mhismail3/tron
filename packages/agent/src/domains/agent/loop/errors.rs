//! Runtime error types.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::shared::server::errors::{INTERNAL_ERROR, SESSION_BUSY, SESSION_NOT_FOUND};
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_CANCELLED, RUNTIME_CAPABILITY_ERROR,
    RUNTIME_CONTEXT_ERROR, RUNTIME_MAX_TURNS, RUNTIME_PERSISTENCE_ERROR, RUNTIME_SERVER_BUSY,
};

/// Errors that can occur during agent runtime execution.
#[derive(Debug, thiserror::Error)]
pub enum RuntimeError {
    /// Model response error (streaming, auth, rate limit).
    #[error("Provider error: {0}")]
    ModelResponse(#[from] crate::domains::model::responder::ModelResponseError),

    /// Capability invocation error.
    #[error("Capability error: {model_primitive_name}: {message}")]
    ModelCapability {
        /// Capability name.
        model_primitive_name: String,
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

    /// Server is at capacity (too many concurrent runs).
    #[error("Server busy: {current}/{max} concurrent runs")]
    ServerBusy {
        /// Current number of active runs.
        current: usize,
        /// Maximum allowed concurrent runs.
        max: usize,
    },

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
            Self::ModelResponse(e) => e.failure().recoverable,
            Self::Cancelled
            | Self::MaxTurns(_)
            | Self::SessionBusy(_)
            | Self::ServerBusy { .. } => true,
            Self::ModelCapability { .. }
            | Self::Context(_)
            | Self::SessionNotFound(_)
            | Self::Persistence(_)
            | Self::Internal(_) => false,
        }
    }

    /// Error category string for event emission.
    pub fn category(&self) -> &str {
        match self {
            Self::ModelResponse(error) => error.category(),
            Self::ModelCapability { .. } => "capability",
            Self::Context(_) => "context",
            Self::Cancelled => "cancelled",
            Self::MaxTurns(_) => "max_turns",
            Self::SessionNotFound(_) => "session_not_found",
            Self::SessionBusy(_) => "session_busy",
            Self::ServerBusy { .. } => "server_busy",
            Self::Persistence(_) => "persistence",
            Self::Internal(_) => "internal",
        }
    }

    /// Convert this runtime error to the canonical failure envelope.
    pub fn to_failure(&self) -> FailureEnvelope {
        match self {
            Self::ModelResponse(error) => error.failure().clone(),
            Self::ModelCapability {
                model_primitive_name,
                message,
            } => FailureEnvelope::new(
                RUNTIME_CAPABILITY_ERROR,
                FailureCategory::Capability,
                message.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            )
            .with_details(Some(serde_json::json!({
                "modelPrimitiveName": model_primitive_name,
            }))),
            Self::Context(message) => FailureEnvelope::new(
                RUNTIME_CONTEXT_ERROR,
                FailureCategory::InvalidRequest,
                message.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            ),
            Self::Cancelled => FailureEnvelope::new(
                RUNTIME_CANCELLED,
                FailureCategory::Cancelled,
                "Operation cancelled",
                false,
                true,
                FailureOrigin::AgentRuntime,
            ),
            Self::MaxTurns(max_turns) => FailureEnvelope::new(
                RUNTIME_MAX_TURNS,
                FailureCategory::Conflict,
                format!("Max turns ({max_turns}) exceeded"),
                false,
                true,
                FailureOrigin::AgentRuntime,
            )
            .with_details(Some(serde_json::json!({ "maxTurns": max_turns }))),
            Self::SessionNotFound(session_id) => FailureEnvelope::new(
                SESSION_NOT_FOUND,
                FailureCategory::NotFound,
                format!("Session not found: {session_id}"),
                false,
                true,
                FailureOrigin::AgentRuntime,
            )
            .with_session_id(Some(session_id.clone())),
            Self::SessionBusy(session_id) => FailureEnvelope::new(
                SESSION_BUSY,
                FailureCategory::Conflict,
                format!("Session busy: {session_id}"),
                true,
                true,
                FailureOrigin::AgentRuntime,
            )
            .with_session_id(Some(session_id.clone())),
            Self::ServerBusy { current, max } => FailureEnvelope::new(
                RUNTIME_SERVER_BUSY,
                FailureCategory::RateLimit,
                format!("Server busy: {current}/{max} concurrent runs"),
                true,
                true,
                FailureOrigin::AgentRuntime,
            )
            .with_details(Some(serde_json::json!({ "current": current, "max": max }))),
            Self::Persistence(message) => FailureEnvelope::new(
                RUNTIME_PERSISTENCE_ERROR,
                FailureCategory::Persistence,
                message.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            ),
            Self::Internal(_) => FailureEnvelope::new(
                INTERNAL_ERROR,
                FailureCategory::Internal,
                "Internal error",
                false,
                false,
                FailureOrigin::AgentRuntime,
            ),
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
    /// A turn-stopping primitive call requested the next loop iteration.
    CapabilityStop,
    /// Unrecoverable error.
    Error,
    /// User abort.
    Interrupted,
    /// Pure text response (no capabilities to execute).
    #[serde(rename = "no_capability_invocations")]
    NoCapabilityInvocationDrafts,
}

impl fmt::Display for StopReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EndTurn => write!(f, "end_turn"),
            Self::MaxTurns => write!(f, "max_turns"),
            Self::CapabilityStop => write!(f, "capability_stop"),
            Self::Error => write!(f, "error"),
            Self::Interrupted => write!(f, "interrupted"),
            Self::NoCapabilityInvocationDrafts => write!(f, "no_capability_invocations"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_error_display() {
        let err = RuntimeError::ModelCapability {
            model_primitive_name: "execute".into(),
            message: "command failed".into(),
        };
        assert_eq!(err.to_string(), "Capability error: execute: command failed");
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
            RuntimeError::ModelCapability {
                model_primitive_name: "t".into(),
                message: "m".into()
            }
            .category(),
            "capability"
        );
    }

    #[test]
    fn runtime_error_is_recoverable() {
        assert!(RuntimeError::Cancelled.is_recoverable());
        assert!(RuntimeError::MaxTurns(5).is_recoverable());
        assert!(RuntimeError::SessionBusy("s".into()).is_recoverable());
        assert!(
            RuntimeError::ServerBusy {
                current: 50,
                max: 50
            }
            .is_recoverable()
        );
        assert!(!RuntimeError::Internal("x".into()).is_recoverable());
        assert!(!RuntimeError::Context("x".into()).is_recoverable());
        assert!(!RuntimeError::SessionNotFound("s".into()).is_recoverable());
    }

    #[test]
    fn server_busy_error() {
        let err = RuntimeError::ServerBusy {
            current: 50,
            max: 50,
        };
        assert_eq!(err.to_string(), "Server busy: 50/50 concurrent runs");
        assert_eq!(err.category(), "server_busy");
        assert!(err.is_recoverable());
    }

    #[test]
    fn runtime_error_to_failure_has_stable_code_and_category() {
        let failure = RuntimeError::ServerBusy {
            current: 50,
            max: 50,
        }
        .to_failure();

        assert_eq!(failure.code, RUNTIME_SERVER_BUSY);
        assert_eq!(failure.category, FailureCategory::RateLimit);
        assert!(failure.retryable);
        assert!(failure.recoverable);
        assert_eq!(failure.details.unwrap()["max"], 50);
    }

    #[test]
    fn runtime_internal_failure_is_sanitized() {
        let failure = RuntimeError::Internal("disk path /tmp/secret failed".into()).to_failure();

        assert_eq!(failure.code, INTERNAL_ERROR);
        assert_eq!(failure.category, FailureCategory::Internal);
        assert_eq!(failure.message, "Internal error");
    }

    #[test]
    fn stop_reason_serde_roundtrip() {
        let reasons = vec![
            StopReason::EndTurn,
            StopReason::MaxTurns,
            StopReason::CapabilityStop,
            StopReason::Error,
            StopReason::Interrupted,
            StopReason::NoCapabilityInvocationDrafts,
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
            serde_json::to_string(&StopReason::CapabilityStop).unwrap(),
            "\"capability_stop\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::NoCapabilityInvocationDrafts).unwrap(),
            "\"no_capability_invocations\""
        );
    }

    #[test]
    fn stop_reason_display() {
        assert_eq!(StopReason::EndTurn.to_string(), "end_turn");
        assert_eq!(StopReason::Interrupted.to_string(), "interrupted");
    }
}
