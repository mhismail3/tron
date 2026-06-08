//! Capability error codes and error type.
//!
//! Domain code uses these typed errors without knowing which transport will
//! serialize them. Transport conversion lives at the client protocol boundary.

// ── Error code constants ────────────────────────────────────────────

/// Invalid or missing parameters.
pub const INVALID_PARAMS: &str = "INVALID_PARAMS";
/// Unexpected internal error.
pub const INTERNAL_ERROR: &str = "INTERNAL_ERROR";
/// Public transport method not found.
/// Resource or feature not available.
pub const NOT_AVAILABLE: &str = "NOT_AVAILABLE";
/// Generic not-found.
pub const NOT_FOUND: &str = "NOT_FOUND";
/// Session does not exist.
pub const SESSION_NOT_FOUND: &str = "SESSION_NOT_FOUND";
/// Session is currently processing a prompt from another connection.
pub const SESSION_BUSY: &str = "SESSION_BUSY";
/// Engine idempotency key replay/conflict could not be accepted.
pub const IDEMPOTENCY_CONFLICT: &str = "IDEMPOTENCY_CONFLICT";
/// Engine catalog mutation targeted an item owned by a different worker.
pub const ENGINE_OWNER_MISMATCH: &str = "ENGINE_OWNER_MISMATCH";
/// Engine visibility promotion request is not allowed.
pub const INVALID_VISIBILITY_PROMOTION: &str = "INVALID_VISIBILITY_PROMOTION";

// ── Typed event-store errors ─────────────────────────────────────────
//
// `EventStoreError` variants get mapped to these codes via
// `map_event_store_error`. Most events/session/memory/blob capabilities should
// use it rather than wrapping into `CapabilityError::Internal`.

/// Requested event was not found.
pub const EVENT_NOT_FOUND: &str = "EVENT_NOT_FOUND";
/// Requested workspace was not found.
pub const WORKSPACE_NOT_FOUND: &str = "WORKSPACE_NOT_FOUND";
/// Requested blob was not found.
pub const BLOB_NOT_FOUND: &str = "BLOB_NOT_FOUND";

// ── Typed auth errors ────────────────────────────────────────────────
//
// `AuthError` variants get mapped to these codes via `map_auth_error`.

/// No authentication configured for the requested provider.
pub const AUTH_NOT_CONFIGURED: &str = "AUTH_NOT_CONFIGURED";
/// OAuth token has expired and refresh failed.
pub const AUTH_TOKEN_EXPIRED: &str = "AUTH_TOKEN_EXPIRED";
/// OAuth flow returned an error from the upstream provider.
pub const AUTH_OAUTH_ERROR: &str = "AUTH_OAUTH_ERROR";

// ── Version handshake (L6) ──────────────────────────────────────────
//
// `system::ping` requires a numeric `protocolVersion` from the client
// and returns the server's current version plus a protocol verdict.
// Version numbers are monotonic integers bumped only on breaking wire-format
// changes.

/// Client advertised a protocol version below
/// [`MIN_CLIENT_PROTOCOL_VERSION`]. The server refuses to serve
/// requests; the client must upgrade.
pub const CLIENT_VERSION_UNSUPPORTED: &str = "CLIENT_VERSION_UNSUPPORTED";

/// Transport-neutral error type returned by canonical capabilities and services.
#[derive(Debug, thiserror::Error)]
pub enum CapabilityError {
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

impl CapabilityError {
    /// Machine-readable error code for this variant.
    pub fn code(&self) -> &str {
        match self {
            Self::InvalidParams { .. } => INVALID_PARAMS,
            Self::NotFound { code, .. } | Self::Custom { code, .. } => code,
            Self::Internal { .. } => INTERNAL_ERROR,
            Self::NotAvailable { .. } => NOT_AVAILABLE,
        }
    }

    /// Structured details attached to this error, when present.
    pub fn details(&self) -> Option<serde_json::Value> {
        match self {
            Self::Custom { details, .. } => details.clone(),
            _ => None,
        }
    }
}

/// Serialize a value to JSON, mapping errors to [`CapabilityError::Internal`].
pub fn to_json_value<T: serde::Serialize>(val: &T) -> Result<serde_json::Value, CapabilityError> {
    serde_json::to_value(val).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_params_code() {
        let err = CapabilityError::InvalidParams {
            message: "bad".into(),
        };
        assert_eq!(err.code(), INVALID_PARAMS);
        assert_eq!(err.to_string(), "bad");
    }

    #[test]
    fn not_found_code() {
        let err = CapabilityError::NotFound {
            code: SESSION_NOT_FOUND.into(),
            message: "gone".into(),
        };
        assert_eq!(err.code(), SESSION_NOT_FOUND);
    }

    #[test]
    fn internal_code() {
        let err = CapabilityError::Internal {
            message: "boom".into(),
        };
        assert_eq!(err.code(), INTERNAL_ERROR);
    }

    #[test]
    fn custom_code_and_details() {
        let err = CapabilityError::Custom {
            code: "MY_CODE".into(),
            message: "custom".into(),
            details: Some(serde_json::json!({"x": 1})),
        };
        assert_eq!(err.code(), "MY_CODE");
        assert_eq!(err.details().unwrap()["x"], 1);
    }

    #[test]
    fn session_busy_code() {
        let err = CapabilityError::Custom {
            code: SESSION_BUSY.into(),
            message: "Session is processing a prompt from another connection".into(),
            details: None,
        };
        assert_eq!(err.code(), SESSION_BUSY);
        assert_eq!(err.code(), "SESSION_BUSY");
        assert!(err.to_string().contains("processing"));
    }

    #[test]
    fn event_store_codes_are_distinct() {
        let codes = [
            SESSION_NOT_FOUND,
            EVENT_NOT_FOUND,
            WORKSPACE_NOT_FOUND,
            BLOB_NOT_FOUND,
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "event-store error codes must be distinct"
        );
    }

    #[test]
    fn auth_codes_are_distinct() {
        let codes = [AUTH_NOT_CONFIGURED, AUTH_TOKEN_EXPIRED, AUTH_OAUTH_ERROR];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "auth error codes must be distinct"
        );
    }

    #[test]
    fn capability_error_without_details() {
        let err = CapabilityError::NotAvailable {
            message: "nope".into(),
        };
        assert_eq!(err.code(), NOT_AVAILABLE);
        assert_eq!(err.to_string(), "nope");
        assert!(err.details().is_none());
    }
}
