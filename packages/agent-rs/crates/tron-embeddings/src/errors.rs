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

    /// `SQLite` error (preserves source chain).
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// Vector storage operation failed (non-SQLite).
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
    use std::error::Error;

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
            (EmbeddingError::NotReady, "Embedding service not ready"),
            (EmbeddingError::Internal("oops".into()), "oops"),
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

    #[test]
    fn error_from_rusqlite() {
        let sqlite_err = rusqlite::Error::QueryReturnedNoRows;
        let err: EmbeddingError = sqlite_err.into();
        assert!(matches!(err, EmbeddingError::Sqlite(_)));
        assert!(err.to_string().contains("SQLite error"));
    }

    #[test]
    fn error_source_chain_preserved() {
        let sqlite_err = rusqlite::Error::QueryReturnedNoRows;
        let err: EmbeddingError = sqlite_err.into();
        let source = err.source().expect("should have source");
        assert!(source.to_string().contains("Query returned no rows"));
    }

    #[test]
    fn sqlite_variant_display() {
        let err = EmbeddingError::Sqlite(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CANTOPEN),
            Some("unable to open database".into()),
        ));
        let msg = err.to_string();
        assert!(msg.starts_with("SQLite error:"));
    }
}
