//! Error types for the cron scheduling system.

/// Errors that can occur in cron operations.
#[derive(Debug, thiserror::Error)]
pub enum CronError {
    /// Invalid cron expression syntax.
    #[error("invalid cron expression: {0}")]
    InvalidExpression(String),

    /// Invalid IANA timezone.
    #[error("invalid timezone: {0}")]
    InvalidTimezone(String),

    /// Validation error on a job definition.
    #[error("validation error: {0}")]
    Validation(String),

    /// Job not found.
    #[error("job not found: {0}")]
    NotFound(String),

    /// Duplicate job name.
    #[error("duplicate job name: {0}")]
    DuplicateName(String),

    /// Configuration file error.
    #[error("config error: {0}")]
    Config(String),

    /// SQLite database error.
    #[error("database error: {0}")]
    Database(String),

    /// Execution error (shell, webhook, agent, etc.).
    #[error("execution error: {0}")]
    Execution(String),

    /// Execution timed out.
    #[error("execution timed out")]
    TimedOut,

    /// Operation cancelled (shutdown or job disabled).
    #[error("cancelled: {0}")]
    Cancelled(String),

    /// I/O error.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

impl From<rusqlite::Error> for CronError {
    fn from(e: rusqlite::Error) -> Self {
        Self::Database(e.to_string())
    }
}

impl From<r2d2::Error> for CronError {
    fn from(e: r2d2::Error) -> Self {
        Self::Database(format!("pool error: {e}"))
    }
}

impl From<serde_json::Error> for CronError {
    fn from(e: serde_json::Error) -> Self {
        Self::Config(format!("JSON error: {e}"))
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cron_error_variants() {
        let e = CronError::InvalidExpression("bad".into());
        assert!(e.to_string().contains("bad"));

        let e = CronError::InvalidTimezone("bad/tz".into());
        assert!(e.to_string().contains("bad/tz"));

        let e = CronError::Validation("too short".into());
        assert!(e.to_string().contains("too short"));

        let e = CronError::NotFound("cron_123".into());
        assert!(e.to_string().contains("cron_123"));

        let e = CronError::DuplicateName("daily".into());
        assert!(e.to_string().contains("daily"));

        let e = CronError::Config("corrupt".into());
        assert!(e.to_string().contains("corrupt"));

        let e = CronError::Database("locked".into());
        assert!(e.to_string().contains("locked"));

        let e = CronError::Execution("failed".into());
        assert!(e.to_string().contains("failed"));

        let e = CronError::TimedOut;
        assert!(e.to_string().contains("timed out"));

        let e = CronError::Cancelled("shutdown".into());
        assert!(e.to_string().contains("shutdown"));
    }

    #[test]
    fn from_rusqlite_error() {
        let e = rusqlite::Error::QueryReturnedNoRows;
        let ce: CronError = e.into();
        assert!(matches!(ce, CronError::Database(_)));
    }

    #[test]
    fn from_serde_error() {
        let e = serde_json::from_str::<serde_json::Value>("invalid").unwrap_err();
        let ce: CronError = e.into();
        assert!(matches!(ce, CronError::Config(_)));
    }
}
