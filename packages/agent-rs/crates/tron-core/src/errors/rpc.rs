//! RPC error types.
//!
//! Typed error hierarchy for JSON-RPC handlers, eliminating string-based
//! error detection. Each error carries a machine-readable code.

use serde::{Deserialize, Serialize};
use std::fmt;

// ─────────────────────────────────────────────────────────────────────────────
// Error codes
// ─────────────────────────────────────────────────────────────────────────────

/// Centralized RPC error codes.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RpcErrorCode {
    // Core
    /// Invalid parameters.
    #[serde(rename = "INVALID_PARAMS")]
    InvalidParams,
    /// Internal server error.
    #[serde(rename = "INTERNAL_ERROR")]
    InternalError,
    /// Method not found.
    #[serde(rename = "METHOD_NOT_FOUND")]
    MethodNotFound,
    /// Resource not available.
    #[serde(rename = "NOT_AVAILABLE")]
    NotAvailable,
    /// Resource not found.
    #[serde(rename = "NOT_FOUND")]
    NotFound,
    /// Invalid operation.
    #[serde(rename = "INVALID_OPERATION")]
    InvalidOperation,

    // Session
    /// Session not found.
    #[serde(rename = "SESSION_NOT_FOUND")]
    SessionNotFound,
    /// Session not active.
    #[serde(rename = "SESSION_NOT_ACTIVE")]
    SessionNotActive,
    /// Maximum sessions reached.
    #[serde(rename = "MAX_SESSIONS_REACHED")]
    MaxSessionsReached,

    // Filesystem
    /// File not found.
    #[serde(rename = "FILE_NOT_FOUND")]
    FileNotFound,
    /// File operation error.
    #[serde(rename = "FILE_ERROR")]
    FileError,
    /// Filesystem error.
    #[serde(rename = "FILESYSTEM_ERROR")]
    FilesystemError,
    /// Resource already exists.
    #[serde(rename = "ALREADY_EXISTS")]
    AlreadyExists,
    /// Invalid file path.
    #[serde(rename = "INVALID_PATH")]
    InvalidPath,
    /// Permission denied.
    #[serde(rename = "PERMISSION_DENIED")]
    PermissionDenied,

    // Tools & Services
    /// Browser automation error.
    #[serde(rename = "BROWSER_ERROR")]
    BrowserError,
    /// Skill execution error.
    #[serde(rename = "SKILL_ERROR")]
    SkillError,
    /// Canvas operation error.
    #[serde(rename = "CANVAS_ERROR")]
    CanvasError,
    /// Tool result failed.
    #[serde(rename = "TOOL_RESULT_FAILED")]
    ToolResultFailed,

    // Media & Communication
    /// Transcription error.
    #[serde(rename = "TRANSCRIPTION_ERROR")]
    TranscriptionError,
    /// Voice note error.
    #[serde(rename = "VOICE_NOTE_ERROR")]
    VoiceNoteError,
    /// Message error.
    #[serde(rename = "MESSAGE_ERROR")]
    MessageError,

    // Git
    /// Git operation error.
    #[serde(rename = "GIT_ERROR")]
    GitError,

    // Device
    /// Device registration error.
    #[serde(rename = "REGISTRATION_ERROR")]
    RegistrationError,
}

impl fmt::Display for RpcErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = serde_json::to_string(self).unwrap_or_else(|_| "UNKNOWN".to_owned());
        // Strip surrounding quotes
        write!(f, "{}", s.trim_matches('"'))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RPC error
// ─────────────────────────────────────────────────────────────────────────────

/// Base RPC error.
#[derive(Clone, Debug)]
pub struct RpcError {
    /// Machine-readable error code.
    pub code: RpcErrorCode,
    /// Human-readable message.
    pub message: String,
}

impl fmt::Display for RpcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for RpcError {}

impl RpcError {
    /// Create a new RPC error.
    #[must_use]
    pub fn new(code: RpcErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    /// Session not found.
    #[must_use]
    pub fn session_not_found(session_id: &str) -> Self {
        Self::new(
            RpcErrorCode::SessionNotFound,
            format!("Session not found: {session_id}"),
        )
    }

    /// Session not active.
    #[must_use]
    pub fn session_not_active(session_id: &str) -> Self {
        Self::new(
            RpcErrorCode::SessionNotActive,
            format!("Session is not active: {session_id}"),
        )
    }

    /// Max sessions reached.
    #[must_use]
    pub fn max_sessions_reached(max_sessions: u32) -> Self {
        Self::new(
            RpcErrorCode::MaxSessionsReached,
            format!(
                "Maximum concurrent sessions ({max_sessions}) reached. \
                 Close an existing session or increase the limit in Settings."
            ),
        )
    }

    /// Manager not available.
    #[must_use]
    pub fn not_available(name: &str) -> Self {
        Self::new(
            RpcErrorCode::NotAvailable,
            format!("{name} is not available"),
        )
    }

    /// Invalid parameters.
    #[must_use]
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::InvalidParams, message)
    }

    /// File not found.
    #[must_use]
    pub fn file_not_found(path: &str) -> Self {
        Self::new(
            RpcErrorCode::FileNotFound,
            format!("File not found: {path}"),
        )
    }

    /// Internal error.
    #[must_use]
    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::InternalError, message)
    }

    /// Browser error.
    #[must_use]
    pub fn browser(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::BrowserError, message)
    }

    /// Skill error.
    #[must_use]
    pub fn skill(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::SkillError, message)
    }

    /// File error.
    #[must_use]
    pub fn file_error(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::FileError, message)
    }

    /// Permission denied.
    #[must_use]
    pub fn permission_denied(message: impl Into<String>) -> Self {
        Self::new(RpcErrorCode::PermissionDenied, message)
    }
}

/// Check if an error is an [`RpcError`].
pub fn is_rpc_error(error: &(dyn std::error::Error + 'static)) -> bool {
    error.downcast_ref::<RpcError>().is_some()
}

// ─────────────────────────────────────────────────────────────────────────────
// Response format
// ─────────────────────────────────────────────────────────────────────────────

/// RPC error response format sent over the wire.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RpcErrorResponse {
    /// Request ID.
    pub id: serde_json::Value,
    /// Always `false`.
    pub success: bool,
    /// Error details.
    pub error: RpcErrorDetail,
}

/// Error detail in an [`RpcErrorResponse`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RpcErrorDetail {
    /// Error code.
    pub code: RpcErrorCode,
    /// Error message.
    pub message: String,
}

/// Convert an [`RpcError`] to a wire-format response.
#[must_use]
pub fn to_rpc_error_response(request_id: serde_json::Value, error: &RpcError) -> RpcErrorResponse {
    RpcErrorResponse {
        id: request_id,
        success: false,
        error: RpcErrorDetail {
            code: error.code.clone(),
            message: error.message.clone(),
        },
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rpc_error_code_serde() {
        assert_eq!(
            serde_json::to_string(&RpcErrorCode::SessionNotFound).unwrap(),
            "\"SESSION_NOT_FOUND\""
        );
        assert_eq!(
            serde_json::to_string(&RpcErrorCode::InvalidParams).unwrap(),
            "\"INVALID_PARAMS\""
        );
    }

    #[test]
    fn rpc_error_code_display() {
        assert_eq!(RpcErrorCode::SessionNotFound.to_string(), "SESSION_NOT_FOUND");
        assert_eq!(RpcErrorCode::InternalError.to_string(), "INTERNAL_ERROR");
    }

    #[test]
    fn rpc_error_display() {
        let err = RpcError::session_not_found("sess-1");
        let display = err.to_string();
        assert!(display.contains("SESSION_NOT_FOUND"));
        assert!(display.contains("sess-1"));
    }

    #[test]
    fn session_not_found_error() {
        let err = RpcError::session_not_found("abc-123");
        assert_eq!(err.code, RpcErrorCode::SessionNotFound);
        assert!(err.message.contains("abc-123"));
    }

    #[test]
    fn session_not_active_error() {
        let err = RpcError::session_not_active("sess-2");
        assert_eq!(err.code, RpcErrorCode::SessionNotActive);
    }

    #[test]
    fn max_sessions_reached_error() {
        let err = RpcError::max_sessions_reached(5);
        assert_eq!(err.code, RpcErrorCode::MaxSessionsReached);
        assert!(err.message.contains('5'));
    }

    #[test]
    fn not_available_error() {
        let err = RpcError::not_available("BrowserManager");
        assert_eq!(err.code, RpcErrorCode::NotAvailable);
        assert!(err.message.contains("BrowserManager"));
    }

    #[test]
    fn invalid_params_error() {
        let err = RpcError::invalid_params("missing field 'name'");
        assert_eq!(err.code, RpcErrorCode::InvalidParams);
    }

    #[test]
    fn file_not_found_error() {
        let err = RpcError::file_not_found("/tmp/missing.txt");
        assert_eq!(err.code, RpcErrorCode::FileNotFound);
    }

    #[test]
    fn internal_error() {
        let err = RpcError::internal("unexpected state");
        assert_eq!(err.code, RpcErrorCode::InternalError);
    }

    #[test]
    fn browser_error() {
        let err = RpcError::browser("page crashed");
        assert_eq!(err.code, RpcErrorCode::BrowserError);
    }

    #[test]
    fn skill_error() {
        let err = RpcError::skill("skill not found");
        assert_eq!(err.code, RpcErrorCode::SkillError);
    }

    #[test]
    fn file_error() {
        let err = RpcError::file_error("read failed");
        assert_eq!(err.code, RpcErrorCode::FileError);
    }

    #[test]
    fn permission_denied_error() {
        let err = RpcError::permission_denied("no write access");
        assert_eq!(err.code, RpcErrorCode::PermissionDenied);
    }

    #[test]
    fn is_rpc_error_positive() {
        let err = RpcError::internal("test");
        assert!(is_rpc_error(&err));
    }

    #[test]
    fn to_rpc_error_response_format() {
        let err = RpcError::session_not_found("sess-1");
        let resp = to_rpc_error_response(json!(42), &err);
        assert_eq!(resp.id, json!(42));
        assert!(!resp.success);
        assert_eq!(resp.error.code, RpcErrorCode::SessionNotFound);

        let json = serde_json::to_value(&resp).unwrap();
        assert_eq!(json["error"]["code"], "SESSION_NOT_FOUND");
    }

    #[test]
    fn rpc_error_response_serde_roundtrip() {
        let resp = RpcErrorResponse {
            id: json!("req-1"),
            success: false,
            error: RpcErrorDetail {
                code: RpcErrorCode::InvalidParams,
                message: "bad param".into(),
            },
        };
        let json = serde_json::to_string(&resp).unwrap();
        let back: RpcErrorResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(resp, back);
    }

    #[test]
    fn all_error_codes_serialize() {
        let codes = vec![
            RpcErrorCode::InvalidParams,
            RpcErrorCode::InternalError,
            RpcErrorCode::MethodNotFound,
            RpcErrorCode::NotAvailable,
            RpcErrorCode::NotFound,
            RpcErrorCode::InvalidOperation,
            RpcErrorCode::SessionNotFound,
            RpcErrorCode::SessionNotActive,
            RpcErrorCode::MaxSessionsReached,
            RpcErrorCode::FileNotFound,
            RpcErrorCode::FileError,
            RpcErrorCode::FilesystemError,
            RpcErrorCode::AlreadyExists,
            RpcErrorCode::InvalidPath,
            RpcErrorCode::PermissionDenied,
            RpcErrorCode::BrowserError,
            RpcErrorCode::SkillError,
            RpcErrorCode::CanvasError,
            RpcErrorCode::ToolResultFailed,
            RpcErrorCode::TranscriptionError,
            RpcErrorCode::VoiceNoteError,
            RpcErrorCode::MessageError,
            RpcErrorCode::GitError,
            RpcErrorCode::RegistrationError,
        ];
        for code in codes {
            let json = serde_json::to_string(&code).unwrap();
            let back: RpcErrorCode = serde_json::from_str(&json).unwrap();
            assert_eq!(code, back);
        }
    }
}
