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
}
