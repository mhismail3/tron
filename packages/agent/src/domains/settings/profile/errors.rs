//! Settings error types.

use thiserror::Error;

/// Errors that can occur when loading or parsing settings.
#[derive(Debug, Error)]
pub enum SettingsError {
    /// Failed to read the settings file from disk.
    #[error("failed to read settings file: {0}")]
    Io(#[from] std::io::Error),
    /// JSON conversion failed inside the settings boundary.
    #[error("settings JSON {operation} failed: {message}")]
    Json {
        /// Settings operation being performed.
        operation: &'static str,
        /// Sanitized conversion details.
        message: String,
    },
    /// A settings value was invalid (e.g., out of range).
    #[error("invalid settings value: {0}")]
    InvalidValue(String),
}

/// Result type for settings operations.
pub type Result<T> = std::result::Result<T, SettingsError>;

impl SettingsError {
    /// Map a JSON implementation error into the settings boundary contract.
    pub(crate) fn json(operation: &'static str, error: impl std::fmt::Display) -> Self {
        Self::Json {
            operation,
            message: error.to_string(),
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
    fn io_error_display() {
        let err = SettingsError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "not found",
        ));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn json_error_display() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalid").unwrap_err();
        let err = SettingsError::json("decode settings", json_err);
        assert!(err.to_string().contains("decode settings"));
    }

    #[test]
    fn invalid_value_display() {
        let err = SettingsError::InvalidValue("port out of range".to_string());
        assert_eq!(err.to_string(), "invalid settings value: port out of range");
    }

    #[test]
    fn io_error_from_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        let err: SettingsError = io_err.into();
        assert!(matches!(err, SettingsError::Io(_)));
    }

    #[test]
    fn json_error_variant_carries_operation() {
        let json_err = serde_json::from_str::<serde_json::Value>("{bad}").unwrap_err();
        let err = SettingsError::json("encode sparse settings", json_err);
        assert!(
            matches!(err, SettingsError::Json { operation, .. } if operation == "encode sparse settings")
        );
    }
}
