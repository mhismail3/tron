//! Token subsystem error types.

use tron_core::messages::ProviderType;

/// Errors that can occur during token processing.
#[derive(Debug, thiserror::Error)]
pub enum TokenError {
    /// Provider did not return usage data.
    #[error("missing token data from {provider:?} on turn {turn} (session {session_id})")]
    MissingData {
        /// Which provider failed to report.
        provider: Option<ProviderType>,
        /// Turn number where the error occurred.
        turn: u64,
        /// Session identifier.
        session_id: String,
        /// Whether partial data was present.
        has_partial_data: bool,
    },

    /// Pricing information not found for the given model.
    #[error("no pricing info for model `{model}`")]
    UnknownModel {
        /// The model identifier.
        model: String,
    },

    /// Invalid token value encountered.
    #[error("invalid token value: {0}")]
    InvalidValue(String),
}

/// Convenience result type.
pub type Result<T> = std::result::Result<T, TokenError>;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_data_display() {
        let err = TokenError::MissingData {
            provider: Some(ProviderType::Anthropic),
            turn: 3,
            session_id: "sess_123".to_string(),
            has_partial_data: false,
        };
        let msg = err.to_string();
        assert!(msg.contains("Anthropic"));
        assert!(msg.contains("turn 3"));
        assert!(msg.contains("sess_123"));
    }

    #[test]
    fn unknown_model_display() {
        let err = TokenError::UnknownModel {
            model: "gpt-5-turbo".to_string(),
        };
        assert!(err.to_string().contains("gpt-5-turbo"));
    }

    #[test]
    fn invalid_value_display() {
        let err = TokenError::InvalidValue("negative token count".to_string());
        assert!(err.to_string().contains("negative token count"));
    }

    #[test]
    fn missing_data_no_provider() {
        let err = TokenError::MissingData {
            provider: None,
            turn: 0,
            session_id: "s".to_string(),
            has_partial_data: true,
        };
        assert!(err.to_string().contains("None"));
    }
}
