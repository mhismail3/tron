//! Capability error codes and error type.
//!
//! Domain code uses these typed errors without knowing which transport will
//! serialize them. Transport conversion lives at the client protocol boundary.

use crate::shared::server::failure::{FailureCategory, FailureEnvelope, FailureOrigin};

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
/// Event store write/read contention exceeded its retry budget.
pub const EVENT_STORE_BUSY: &str = "EVENT_STORE_BUSY";
/// Event store failed without a narrower public classification.
pub const EVENT_STORE_FAILURE: &str = "EVENT_STORE_FAILURE";

// ── Typed auth errors ────────────────────────────────────────────────
//
// `AuthError` variants get mapped to these codes via `map_auth_error`.

/// No authentication configured for the requested provider.
pub const AUTH_NOT_CONFIGURED: &str = "AUTH_NOT_CONFIGURED";
/// OAuth token has expired and refresh failed.
pub const AUTH_TOKEN_EXPIRED: &str = "AUTH_TOKEN_EXPIRED";
/// OAuth flow returned an error from the upstream provider.
pub const AUTH_OAUTH_ERROR: &str = "AUTH_OAUTH_ERROR";
/// Auth credential storage is malformed or unavailable.
pub const AUTH_STORAGE_ERROR: &str = "AUTH_STORAGE_ERROR";
/// Auth provider transport failed before a usable OAuth response.
pub const AUTH_TRANSPORT_ERROR: &str = "AUTH_TRANSPORT_ERROR";

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

    /// Convert this capability error to the canonical failure envelope.
    pub fn to_failure(&self, origin: FailureOrigin) -> FailureEnvelope {
        let message = self.public_message();
        let code = self.code().to_owned();
        let category = category_for_capability_code(&code);
        let (retryable, recoverable) = retry_recover_for_category(category, &code);
        FailureEnvelope::new(code, category, message, retryable, recoverable, origin)
            .with_details(self.details())
    }

    /// Build a capability error that preserves a canonical failure envelope in
    /// structured details for capability and engine result paths.
    pub fn from_failure(failure: FailureEnvelope) -> Self {
        let code = failure.code.clone();
        let message = failure.message.clone();
        let details = Some(failure.details_with_failure());
        if failure.details.is_some()
            || failure.provider.is_some()
            || failure.model.is_some()
            || failure.status_code.is_some()
            || failure.error_type.is_some()
            || failure.retry_after_ms.is_some()
            || failure.suggestion.is_some()
            || failure.references != Default::default()
        {
            return Self::Custom {
                code,
                message,
                details,
            };
        }
        match code.as_str() {
            INVALID_PARAMS => Self::InvalidParams { message },
            INTERNAL_ERROR => Self::Internal { message },
            NOT_AVAILABLE => Self::NotAvailable { message },
            NOT_FOUND | SESSION_NOT_FOUND | EVENT_NOT_FOUND | WORKSPACE_NOT_FOUND
            | BLOB_NOT_FOUND => Self::NotFound { code, message },
            _ => Self::Custom {
                code,
                message,
                details,
            },
        }
    }

    fn public_message(&self) -> String {
        match self {
            Self::InvalidParams { message }
            | Self::NotFound { message, .. }
            | Self::NotAvailable { message }
            | Self::Custom { message, .. } => message.clone(),
            Self::Internal { .. } => "Internal error".to_string(),
        }
    }
}

fn category_for_capability_code(code: &str) -> FailureCategory {
    match code {
        INVALID_PARAMS | CLIENT_VERSION_UNSUPPORTED | INVALID_VISIBILITY_PROMOTION => {
            FailureCategory::InvalidRequest
        }
        SESSION_NOT_FOUND | EVENT_NOT_FOUND | WORKSPACE_NOT_FOUND | BLOB_NOT_FOUND | NOT_FOUND => {
            FailureCategory::NotFound
        }
        NOT_AVAILABLE | EVENT_STORE_BUSY => FailureCategory::Unavailable,
        SESSION_BUSY | IDEMPOTENCY_CONFLICT | ENGINE_OWNER_MISMATCH => FailureCategory::Conflict,
        AUTH_NOT_CONFIGURED | AUTH_TOKEN_EXPIRED | AUTH_OAUTH_ERROR | AUTH_STORAGE_ERROR => {
            FailureCategory::Auth
        }
        AUTH_TRANSPORT_ERROR => FailureCategory::Network,
        EVENT_STORE_FAILURE => FailureCategory::Persistence,
        INTERNAL_ERROR => FailureCategory::Internal,
        _ => FailureCategory::Unknown,
    }
}

fn retry_recover_for_category(category: FailureCategory, code: &str) -> (bool, bool) {
    match (category, code) {
        (FailureCategory::Conflict, SESSION_BUSY) => (true, true),
        (FailureCategory::Conflict, IDEMPOTENCY_CONFLICT | ENGINE_OWNER_MISMATCH) => (false, true),
        (FailureCategory::Unavailable, _) => (true, true),
        (FailureCategory::Network, _) => (true, true),
        (FailureCategory::NotFound, _) | (FailureCategory::InvalidRequest, _) => (false, true),
        (FailureCategory::Auth, _) => (false, true),
        (FailureCategory::Internal, _) => (false, false),
        _ => (false, false),
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

    #[test]
    fn capability_error_to_failure_preserves_code_and_details() {
        let err = CapabilityError::Custom {
            code: SESSION_BUSY.into(),
            message: "Session is busy".into(),
            details: Some(serde_json::json!({"sessionId": "s1"})),
        };

        let failure = err.to_failure(FailureOrigin::Transport);

        assert_eq!(failure.code, SESSION_BUSY);
        assert_eq!(failure.category, FailureCategory::Conflict);
        assert_eq!(failure.message, "Session is busy");
        assert!(failure.retryable);
        assert!(failure.recoverable);
        assert_eq!(failure.origin, FailureOrigin::Transport);
        assert_eq!(failure.details.unwrap()["sessionId"], "s1");
    }

    #[test]
    fn capability_internal_failure_uses_sanitized_public_message() {
        let err = CapabilityError::Internal {
            message: "disk path /tmp/secret failed".into(),
        };

        let failure = err.to_failure(FailureOrigin::Server);

        assert_eq!(failure.code, INTERNAL_ERROR);
        assert_eq!(failure.category, FailureCategory::Internal);
        assert_eq!(failure.message, "Internal error");
        assert!(!failure.retryable);
        assert!(!failure.recoverable);
    }

    #[test]
    fn capability_error_from_failure_embeds_envelope_details() {
        let failure = FailureEnvelope::new(
            IDEMPOTENCY_CONFLICT,
            FailureCategory::Conflict,
            "conflict",
            false,
            true,
            FailureOrigin::Engine,
        )
        .with_details(Some(serde_json::json!({"key": "abc"})));

        let err = CapabilityError::from_failure(failure);

        assert_eq!(err.code(), IDEMPOTENCY_CONFLICT);
        let details = err.details().expect("failure details");
        assert_eq!(details["key"], "abc");
        assert_eq!(details["failure"]["code"], IDEMPOTENCY_CONFLICT);
        assert_eq!(details["failure"]["category"], "conflict");
    }
}
