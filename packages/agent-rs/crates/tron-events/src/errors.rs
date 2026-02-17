//! Error types for the event store subsystem.
//!
//! [`EventStoreError`] is the primary error type returned by all event store
//! operations. It provides specific variants for common failure modes while
//! keeping the surface area small enough for exhaustive pattern matching.

use thiserror::Error;

/// Errors that can occur during event store operations.
#[derive(Debug, Error)]
pub enum EventStoreError {
    /// `SQLite` database error.
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    /// Connection pool error.
    #[error("connection pool error: {0}")]
    Pool(#[from] r2d2::Error),

    /// JSON serialization/deserialization error.
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),

    /// Schema migration failed.
    #[error("migration error: {message}")]
    Migration {
        /// Describes which migration failed and why.
        message: String,
    },

    /// Requested session was not found.
    #[error("session not found: {0}")]
    SessionNotFound(String),

    /// Requested event was not found.
    #[error("event not found: {0}")]
    EventNotFound(String),

    /// Requested workspace was not found.
    #[error("workspace not found: {0}")]
    WorkspaceNotFound(String),

    /// Requested blob was not found.
    #[error("blob not found: {0}")]
    BlobNotFound(String),

    /// Invalid operation on the event store.
    #[error("invalid operation: {0}")]
    InvalidOperation(String),

    /// Internal error (e.g. poisoned lock).
    #[error("internal error: {0}")]
    Internal(String),
}

/// Convenience type alias for event store results.
pub type Result<T> = std::result::Result<T, EventStoreError>;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sqlite_error_display() {
        let err = EventStoreError::Sqlite(rusqlite::Error::QueryReturnedNoRows);
        assert!(err.to_string().contains("sqlite error"));
    }

    #[test]
    fn serde_error_display() {
        let serde_err = serde_json::from_str::<String>("not json").unwrap_err();
        let err = EventStoreError::Serde(serde_err);
        assert!(err.to_string().contains("serde error"));
    }

    #[test]
    fn migration_error_display() {
        let err = EventStoreError::Migration {
            message: "v003 failed: table already exists".into(),
        };
        assert_eq!(
            err.to_string(),
            "migration error: v003 failed: table already exists"
        );
    }

    #[test]
    fn session_not_found_display() {
        let err = EventStoreError::SessionNotFound("sess-123".into());
        assert_eq!(err.to_string(), "session not found: sess-123");
    }

    #[test]
    fn event_not_found_display() {
        let err = EventStoreError::EventNotFound("evt-456".into());
        assert_eq!(err.to_string(), "event not found: evt-456");
    }

    #[test]
    fn workspace_not_found_display() {
        let err = EventStoreError::WorkspaceNotFound("ws-789".into());
        assert_eq!(err.to_string(), "workspace not found: ws-789");
    }

    #[test]
    fn blob_not_found_display() {
        let err = EventStoreError::BlobNotFound("blob-abc".into());
        assert_eq!(err.to_string(), "blob not found: blob-abc");
    }

    #[test]
    fn invalid_operation_display() {
        let err = EventStoreError::InvalidOperation("cannot fork ended session".into());
        assert_eq!(
            err.to_string(),
            "invalid operation: cannot fork ended session"
        );
    }

    #[test]
    fn from_rusqlite_error() {
        let sqlite_err = rusqlite::Error::QueryReturnedNoRows;
        let err: EventStoreError = sqlite_err.into();
        assert!(matches!(err, EventStoreError::Sqlite(_)));
    }

    #[test]
    fn from_serde_error() {
        let serde_err = serde_json::from_str::<String>("bad").unwrap_err();
        let err: EventStoreError = serde_err.into();
        assert!(matches!(err, EventStoreError::Serde(_)));
    }

    #[test]
    fn result_alias() {
        fn example() -> Result<String> {
            Ok("hello".into())
        }
        assert_eq!(example().unwrap(), "hello");
    }
}
