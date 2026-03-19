//! Auth error types.

/// Errors that can occur during authentication operations.
#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    /// HTTP request failed.
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON serialization/deserialization failed.
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// File I/O error.
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// OAuth token exchange or refresh failed.
    #[error("OAuth error ({status}): {message}")]
    OAuth {
        /// HTTP status code (0 if no response).
        status: u16,
        /// Error description.
        message: String,
    },

    /// Token has expired and refresh failed.
    #[error("token expired and refresh failed: {0}")]
    TokenExpired(String),

    /// No authentication configured for the given provider.
    #[error("no auth configured for provider: {0}")]
    NotConfigured(String),
}

impl AuthError {
    /// Whether this error is transient and worth retrying.
    pub fn is_transient(&self) -> bool {
        match self {
            Self::Http(e) => {
                e.is_timeout()
                    || e.is_connect()
                    || e.status()
                        .is_some_and(|s| s.is_server_error() || s == reqwest::StatusCode::TOO_MANY_REQUESTS)
            }
            Self::OAuth { status, .. } => matches!(status, 408 | 429 | 502 | 503 | 504),
            Self::TokenExpired(_) | Self::NotConfigured(_) | Self::Json(_) | Self::Io(_) => false,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn oauth_error_display() {
        let err = AuthError::OAuth {
            status: 401,
            message: "invalid_grant".to_string(),
        };
        assert_eq!(err.to_string(), "OAuth error (401): invalid_grant");
    }

    #[test]
    fn not_configured_display() {
        let err = AuthError::NotConfigured("anthropic".to_string());
        assert_eq!(
            err.to_string(),
            "no auth configured for provider: anthropic"
        );
    }

    #[test]
    fn token_expired_display() {
        let err = AuthError::TokenExpired("refresh returned 403".to_string());
        assert!(err.to_string().contains("refresh returned 403"));
    }

    #[test]
    fn io_error_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "not found");
        let auth_err = AuthError::from(io_err);
        assert!(auth_err.to_string().contains("not found"));
    }

    // ── is_transient ──────────────────────────────────────────────────

    #[test]
    fn oauth_503_is_transient() {
        let err = AuthError::OAuth { status: 503, message: "upstream error".into() };
        assert!(err.is_transient());
    }

    #[test]
    fn oauth_502_is_transient() {
        let err = AuthError::OAuth { status: 502, message: "bad gateway".into() };
        assert!(err.is_transient());
    }

    #[test]
    fn oauth_504_is_transient() {
        let err = AuthError::OAuth { status: 504, message: "timeout".into() };
        assert!(err.is_transient());
    }

    #[test]
    fn oauth_429_is_transient() {
        let err = AuthError::OAuth { status: 429, message: "rate limited".into() };
        assert!(err.is_transient());
    }

    #[test]
    fn oauth_408_is_transient() {
        let err = AuthError::OAuth { status: 408, message: "request timeout".into() };
        assert!(err.is_transient());
    }

    #[test]
    fn oauth_401_is_not_transient() {
        let err = AuthError::OAuth { status: 401, message: "unauthorized".into() };
        assert!(!err.is_transient());
    }

    #[test]
    fn oauth_403_is_not_transient() {
        let err = AuthError::OAuth { status: 403, message: "forbidden".into() };
        assert!(!err.is_transient());
    }

    #[test]
    fn oauth_400_is_not_transient() {
        let err = AuthError::OAuth { status: 400, message: "bad request".into() };
        assert!(!err.is_transient());
    }

    #[test]
    fn not_configured_is_not_transient() {
        let err = AuthError::NotConfigured("anthropic".into());
        assert!(!err.is_transient());
    }

    #[test]
    fn token_expired_is_not_transient() {
        let err = AuthError::TokenExpired("refresh failed".into());
        assert!(!err.is_transient());
    }

    #[test]
    fn json_error_is_not_transient() {
        let err = AuthError::Json(serde_json::from_str::<serde_json::Value>("{{").unwrap_err());
        assert!(!err.is_transient());
    }

    #[test]
    fn io_error_is_not_transient() {
        let err = AuthError::Io(std::io::Error::new(std::io::ErrorKind::NotFound, "nope"));
        assert!(!err.is_transient());
    }
}
