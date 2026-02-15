use std::time::Duration;

/// Typed error hierarchy for LLM gateway operations.
/// Classifies errors as fatal (don't retry), retryable, or operational.
#[derive(Clone, Debug, thiserror::Error)]
pub enum GatewayError {
    // Fatal — don't retry
    #[error("authentication failed: {0}")]
    AuthenticationFailed(String),
    #[error("context window exceeded: {actual} > {limit}")]
    ContextWindowExceeded { limit: usize, actual: usize },
    #[error("invalid request: {0}")]
    InvalidRequest(String),

    // Retryable
    #[error("rate limited")]
    RateLimited { retry_after: Option<Duration> },
    #[error("server error {status}: {body}")]
    ServerError { status: u16, body: String },
    #[error("provider overloaded")]
    ProviderOverloaded,
    #[error("network error: {0}")]
    NetworkError(String),
    #[error("stream interrupted: {0}")]
    StreamInterrupted(String),

    // Operational
    #[error("timeout after {0:?}")]
    Timeout(Duration),
    #[error("cancelled")]
    Cancelled,
}

impl GatewayError {
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            Self::RateLimited { .. }
                | Self::ServerError { .. }
                | Self::ProviderOverloaded
                | Self::NetworkError(_)
                | Self::StreamInterrupted(_)
        )
    }

    pub fn is_fatal(&self) -> bool {
        matches!(
            self,
            Self::AuthenticationFailed(_) | Self::ContextWindowExceeded { .. } | Self::InvalidRequest(_)
        )
    }

    pub fn suggested_delay(&self) -> Option<Duration> {
        if let Self::RateLimited { retry_after } = self {
            *retry_after
        } else {
            None
        }
    }

    /// Short classification string for logging/metrics.
    pub fn error_kind(&self) -> &'static str {
        match self {
            Self::AuthenticationFailed(_) => "authentication_failed",
            Self::ContextWindowExceeded { .. } => "context_window_exceeded",
            Self::InvalidRequest(_) => "invalid_request",
            Self::RateLimited { .. } => "rate_limited",
            Self::ServerError { .. } => "server_error",
            Self::ProviderOverloaded => "provider_overloaded",
            Self::NetworkError(_) => "network_error",
            Self::StreamInterrupted(_) => "stream_interrupted",
            Self::Timeout(_) => "timeout",
            Self::Cancelled => "cancelled",
        }
    }

    /// Classify an HTTP status code into the appropriate error variant.
    pub fn from_status(status: u16, body: String) -> Self {
        match status {
            401 | 403 => Self::AuthenticationFailed(body),
            400 => Self::InvalidRequest(body),
            429 => Self::RateLimited { retry_after: None },
            529 => Self::ProviderOverloaded,
            500..=599 => Self::ServerError { status, body },
            _ => Self::InvalidRequest(format!("unexpected status {status}: {body}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retryable_classification() {
        assert!(GatewayError::RateLimited { retry_after: None }.is_retryable());
        assert!(GatewayError::ServerError { status: 500, body: "err".into() }.is_retryable());
        assert!(GatewayError::ProviderOverloaded.is_retryable());
        assert!(GatewayError::NetworkError("tcp".into()).is_retryable());
        assert!(GatewayError::StreamInterrupted("eof".into()).is_retryable());
    }

    #[test]
    fn fatal_classification() {
        assert!(GatewayError::AuthenticationFailed("bad key".into()).is_fatal());
        assert!(GatewayError::ContextWindowExceeded { limit: 200_000, actual: 250_000 }.is_fatal());
        assert!(GatewayError::InvalidRequest("bad".into()).is_fatal());
    }

    #[test]
    fn not_retryable_and_not_fatal() {
        let timeout = GatewayError::Timeout(Duration::from_secs(30));
        assert!(!timeout.is_retryable());
        assert!(!timeout.is_fatal());

        let cancelled = GatewayError::Cancelled;
        assert!(!cancelled.is_retryable());
        assert!(!cancelled.is_fatal());
    }

    #[test]
    fn suggested_delay_only_for_rate_limit() {
        let rl = GatewayError::RateLimited {
            retry_after: Some(Duration::from_secs(5)),
        };
        assert_eq!(rl.suggested_delay(), Some(Duration::from_secs(5)));

        let se = GatewayError::ServerError { status: 500, body: "err".into() };
        assert_eq!(se.suggested_delay(), None);
    }

    #[test]
    fn from_status_mapping() {
        assert!(GatewayError::from_status(401, "unauthorized".into()).is_fatal());
        assert!(GatewayError::from_status(403, "forbidden".into()).is_fatal());
        assert!(GatewayError::from_status(400, "bad request".into()).is_fatal());
        assert!(GatewayError::from_status(429, "rate limited".into()).is_retryable());
        assert!(GatewayError::from_status(529, "overloaded".into()).is_retryable());
        assert!(GatewayError::from_status(500, "internal".into()).is_retryable());
        assert!(GatewayError::from_status(502, "bad gateway".into()).is_retryable());
    }

    #[test]
    fn error_kind_strings() {
        assert_eq!(GatewayError::Cancelled.error_kind(), "cancelled");
        assert_eq!(GatewayError::ProviderOverloaded.error_kind(), "provider_overloaded");
        assert_eq!(
            GatewayError::RateLimited { retry_after: None }.error_kind(),
            "rate_limited"
        );
    }
}
