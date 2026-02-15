#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("conflict: {0}")]
    Conflict(String),

    #[error("serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("corrupt row in {table}.{column}: {detail}")]
    CorruptRow {
        table: &'static str,
        column: &'static str,
        detail: String,
    },
}

impl StoreError {
    pub fn error_kind(&self) -> &'static str {
        match self {
            Self::Database(_) => "database",
            Self::NotFound(_) => "not_found",
            Self::Conflict(_) => "conflict",
            Self::Serialization(_) => "serialization",
            Self::Io(_) => "io",
            Self::CorruptRow { .. } => "corrupt_row",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::error::Error;

    use super::*;

    #[test]
    fn from_rusqlite_preserves_source() {
        let sqlite_err = rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
            Some("database is locked".into()),
        );
        let store_err = StoreError::from(sqlite_err);
        assert!(matches!(store_err, StoreError::Database(_)));
        assert!(store_err.source().is_some());
    }

    #[test]
    fn from_serde_preserves_source() {
        let json_err = serde_json::from_str::<i32>("not_json").unwrap_err();
        let store_err = StoreError::from(json_err);
        assert!(matches!(store_err, StoreError::Serialization(_)));
        assert!(store_err.source().is_some());
    }

    #[test]
    fn from_io_preserves_source() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "no access");
        let store_err = StoreError::from(io_err);
        assert!(matches!(store_err, StoreError::Io(_)));
        assert!(store_err.source().is_some());
    }

    #[test]
    fn corrupt_row_has_context() {
        let err = StoreError::CorruptRow {
            table: "events",
            column: "payload",
            detail: "expected JSON, got empty string".into(),
        };
        let msg = err.to_string();
        assert!(msg.contains("events"));
        assert!(msg.contains("payload"));
        assert!(msg.contains("expected JSON"));
    }

    #[test]
    fn error_kind_classification() {
        assert_eq!(
            StoreError::Database(rusqlite::Error::InvalidQuery).error_kind(),
            "database"
        );
        assert_eq!(StoreError::NotFound("x".into()).error_kind(), "not_found");
        assert_eq!(StoreError::Conflict("x".into()).error_kind(), "conflict");

        let json_err = serde_json::from_str::<i32>("bad").unwrap_err();
        assert_eq!(
            StoreError::Serialization(json_err).error_kind(),
            "serialization"
        );

        let io_err = std::io::Error::other("fail");
        assert_eq!(StoreError::Io(io_err).error_kind(), "io");

        let err = StoreError::CorruptRow {
            table: "t",
            column: "c",
            detail: "bad".into(),
        };
        assert_eq!(err.error_kind(), "corrupt_row");
    }

    #[test]
    fn display_formatting() {
        let err = StoreError::NotFound("session sess_123".into());
        assert_eq!(err.to_string(), "not found: session sess_123");

        let err = StoreError::CorruptRow {
            table: "sessions",
            column: "status",
            detail: "unknown variant: INVALID".into(),
        };
        assert_eq!(
            err.to_string(),
            "corrupt row in sessions.status: unknown variant: INVALID"
        );
    }
}
