//! Settings error types.

use thiserror::Error;

/// Errors that can occur when loading or parsing settings.
#[derive(Debug, Error)]
pub enum SettingsError {
    /// Failed to read the settings file from disk.
    #[error("failed to read settings file: {0}")]
    Io(#[from] std::io::Error),
    /// Failed to parse JSON in the settings file.
    #[error("failed to parse settings JSON: {0}")]
    Json(#[from] serde_json::Error),
    /// A settings value was invalid (e.g., out of range).
    #[error("invalid settings value: {0}")]
    InvalidValue(String),
}

/// Result type for settings operations.
pub type Result<T> = std::result::Result<T, SettingsError>;

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
        let err = SettingsError::Json(json_err);
        assert!(err.to_string().contains("parse settings JSON"));
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
    fn json_error_from_conversion() {
        let json_err = serde_json::from_str::<serde_json::Value>("{bad}").unwrap_err();
        let err: SettingsError = json_err.into();
        assert!(matches!(err, SettingsError::Json(_)));
    }
}
