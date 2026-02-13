//! RPC error codes and error type.

use crate::types::RpcErrorBody;

// ── Error code constants ────────────────────────────────────────────

/// Invalid or missing parameters.
pub const INVALID_PARAMS: &str = "INVALID_PARAMS";
/// Unexpected internal error.
pub const INTERNAL_ERROR: &str = "INTERNAL_ERROR";
/// Method not found in the registry.
pub const METHOD_NOT_FOUND: &str = "METHOD_NOT_FOUND";
/// Resource or feature not available.
pub const NOT_AVAILABLE: &str = "NOT_AVAILABLE";
/// Generic not-found.
pub const NOT_FOUND: &str = "NOT_FOUND";
/// Operation not valid in current state.
pub const INVALID_OPERATION: &str = "INVALID_OPERATION";
/// Session does not exist.
pub const SESSION_NOT_FOUND: &str = "SESSION_NOT_FOUND";
/// Session exists but is not active.
pub const SESSION_NOT_ACTIVE: &str = "SESSION_NOT_ACTIVE";
/// Concurrent session limit reached.
pub const MAX_SESSIONS_REACHED: &str = "MAX_SESSIONS_REACHED";
/// File does not exist.
pub const FILE_NOT_FOUND: &str = "FILE_NOT_FOUND";
/// Generic file I/O error.
pub const FILE_ERROR: &str = "FILE_ERROR";
/// Filesystem operation error.
pub const FILESYSTEM_ERROR: &str = "FILESYSTEM_ERROR";
/// Resource already exists.
pub const ALREADY_EXISTS: &str = "ALREADY_EXISTS";
/// Path is invalid or unsafe.
pub const INVALID_PATH: &str = "INVALID_PATH";
/// Permission denied.
pub const PERMISSION_DENIED: &str = "PERMISSION_DENIED";
/// Browser streaming error.
pub const BROWSER_ERROR: &str = "BROWSER_ERROR";
/// Skill loading/execution error.
pub const SKILL_ERROR: &str = "SKILL_ERROR";
/// Canvas error.
pub const CANVAS_ERROR: &str = "CANVAS_ERROR";
/// Tool result submission failed.
pub const TOOL_RESULT_FAILED: &str = "TOOL_RESULT_FAILED";
/// Transcription error.
pub const TRANSCRIPTION_ERROR: &str = "TRANSCRIPTION_ERROR";
/// Voice note error.
pub const VOICE_NOTE_ERROR: &str = "VOICE_NOTE_ERROR";
/// Message operation error.
pub const MESSAGE_ERROR: &str = "MESSAGE_ERROR";
/// Git operation error.
pub const GIT_ERROR: &str = "GIT_ERROR";
/// Device registration error.
pub const REGISTRATION_ERROR: &str = "REGISTRATION_ERROR";

/// RPC error type returned by handlers.
#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    /// Required parameter missing or wrong type.
    #[error("{message}")]
    InvalidParams {
        /// Description of what is wrong.
        message: String,
    },

    /// Requested resource not found.
    #[error("{message}")]
    NotFound {
        /// Specific error code (e.g. `SESSION_NOT_FOUND`).
        code: String,
        /// Human-readable message.
        message: String,
    },

    /// Internal server error.
    #[error("{message}")]
    Internal {
        /// Description.
        message: String,
    },

    /// Feature or resource not available.
    #[error("{message}")]
    NotAvailable {
        /// Description.
        message: String,
    },

    /// Domain-specific error with arbitrary code.
    #[error("{message}")]
    Custom {
        /// Machine-readable code.
        code: String,
        /// Human-readable message.
        message: String,
        /// Optional structured details.
        details: Option<serde_json::Value>,
    },
}

impl RpcError {
    /// Machine-readable error code for this variant.
    pub fn code(&self) -> &str {
        match self {
            Self::InvalidParams { .. } => INVALID_PARAMS,
            Self::NotFound { code, .. } | Self::Custom { code, .. } => code,
            Self::Internal { .. } => INTERNAL_ERROR,
            Self::NotAvailable { .. } => NOT_AVAILABLE,
        }
    }

    /// Convert to the wire-format error body.
    pub fn to_error_body(&self) -> RpcErrorBody {
        RpcErrorBody {
            code: self.code().to_owned(),
            message: self.to_string(),
            details: match self {
                Self::Custom { details, .. } => details.clone(),
                _ => None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_params_code() {
        let err = RpcError::InvalidParams { message: "bad".into() };
        assert_eq!(err.code(), INVALID_PARAMS);
        assert_eq!(err.to_string(), "bad");
    }

    #[test]
    fn not_found_code() {
        let err = RpcError::NotFound {
            code: SESSION_NOT_FOUND.into(),
            message: "gone".into(),
        };
        assert_eq!(err.code(), SESSION_NOT_FOUND);
    }

    #[test]
    fn internal_code() {
        let err = RpcError::Internal { message: "boom".into() };
        assert_eq!(err.code(), INTERNAL_ERROR);
    }

    #[test]
    fn custom_code_and_details() {
        let err = RpcError::Custom {
            code: "MY_CODE".into(),
            message: "custom".into(),
            details: Some(serde_json::json!({"x": 1})),
        };
        assert_eq!(err.code(), "MY_CODE");
        let body = err.to_error_body();
        assert_eq!(body.code, "MY_CODE");
        assert_eq!(body.details.unwrap()["x"], 1);
    }

    #[test]
    fn to_error_body_without_details() {
        let err = RpcError::NotAvailable { message: "nope".into() };
        assert_eq!(err.code(), NOT_AVAILABLE);
        let body = err.to_error_body();
        assert_eq!(body.code, NOT_AVAILABLE);
        assert_eq!(body.message, "nope");
        assert!(body.details.is_none());
    }
}
