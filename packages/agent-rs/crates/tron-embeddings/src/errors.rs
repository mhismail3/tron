//! Embedding error types.
//!
//! All embedding errors are non-fatal — the system degrades gracefully
//! when embeddings are unavailable.

use thiserror::Error;

/// Errors from embedding operations.
#[derive(Debug, Error)]
pub enum EmbeddingError {
    /// Model initialization failed.
    #[error("Model initialization failed: {0}")]
    ModelInit(String),

    /// Inference failed.
    #[error("Inference failed: {0}")]
    Inference(String),

    /// Vector storage operation failed.
    #[error("Storage failed: {0}")]
    Storage(String),

    /// Configuration error.
    #[error("Config error: {0}")]
    Config(String),

    /// Service not ready (model not loaded).
    #[error("Embedding service not ready")]
    NotReady,

    /// Generic internal error.
    #[error("{0}")]
    Internal(String),
}

/// Result alias for embedding operations.
pub type Result<T> = std::result::Result<T, EmbeddingError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_display_variants() {
        let cases = vec![
            (
                EmbeddingError::ModelInit("ort failed".into()),
                "Model initialization failed: ort failed",
            ),
            (
                EmbeddingError::Inference("timeout".into()),
                "Inference failed: timeout",
            ),
            (
                EmbeddingError::Storage("disk full".into()),
                "Storage failed: disk full",
            ),
            (
                EmbeddingError::Config("missing field".into()),
                "Config error: missing field",
            ),
            (
                EmbeddingError::NotReady,
                "Embedding service not ready",
            ),
            (
                EmbeddingError::Internal("oops".into()),
                "oops",
            ),
        ];
        for (err, expected) in cases {
            assert_eq!(err.to_string(), expected);
        }
    }

    #[test]
    fn error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<EmbeddingError>();
    }

    #[test]
    #[allow(clippy::unnecessary_wraps)]
    fn result_alias_works() {
        fn returns_ok() -> Result<i32> {
            Ok(42)
        }
        fn returns_err() -> Result<i32> {
            Err(EmbeddingError::NotReady)
        }
        assert_eq!(returns_ok().unwrap(), 42);
        assert!(returns_err().is_err());
    }
}
