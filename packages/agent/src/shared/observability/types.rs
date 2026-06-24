//! Logging types shared across the crate.

use serde::{Deserialize, Serialize};

/// Log level with numeric mapping for `SQLite` filtering.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    /// Detailed entry/exit points.
    Trace = 10,
    /// Intermediate values, decisions.
    Debug = 20,
    /// Outcomes, summaries (default persistence level).
    Info = 30,
    /// Non-fatal issues.
    Warn = 40,
    /// Errors.
    Error = 50,
    /// Unrecoverable errors.
    Fatal = 60,
}

impl LogLevel {
    /// Numeric value for SQL queries (higher = more severe).
    #[must_use]
    pub const fn as_num(self) -> i32 {
        self as i32
    }

    /// Convert from tracing level.
    #[must_use]
    pub fn from_tracing(level: &tracing::Level) -> Self {
        match *level {
            tracing::Level::TRACE => Self::Trace,
            tracing::Level::DEBUG => Self::Debug,
            tracing::Level::INFO => Self::Info,
            tracing::Level::WARN => Self::Warn,
            tracing::Level::ERROR => Self::Error,
        }
    }

    /// Convert from string (case-insensitive).
    #[must_use]
    pub fn from_str_lossy(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "trace" => Self::Trace,
            "debug" => Self::Debug,
            "warn" | "warning" => Self::Warn,
            "error" => Self::Error,
            "fatal" => Self::Fatal,
            _ => Self::Info,
        }
    }
}

impl std::fmt::Display for LogLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Trace => write!(f, "trace"),
            Self::Debug => write!(f, "debug"),
            Self::Info => write!(f, "info"),
            Self::Warn => write!(f, "warn"),
            Self::Error => write!(f, "error"),
            Self::Fatal => write!(f, "fatal"),
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
    fn log_level_ordering() {
        assert!(LogLevel::Trace < LogLevel::Debug);
        assert!(LogLevel::Debug < LogLevel::Info);
        assert!(LogLevel::Info < LogLevel::Warn);
        assert!(LogLevel::Warn < LogLevel::Error);
        assert!(LogLevel::Error < LogLevel::Fatal);
    }

    #[test]
    fn log_level_numeric() {
        assert_eq!(LogLevel::Trace.as_num(), 10);
        assert_eq!(LogLevel::Info.as_num(), 30);
        assert_eq!(LogLevel::Error.as_num(), 50);
        assert_eq!(LogLevel::Fatal.as_num(), 60);
    }

    #[test]
    fn log_level_serde() {
        assert_eq!(serde_json::to_string(&LogLevel::Warn).unwrap(), "\"warn\"");
        let back: LogLevel = serde_json::from_str("\"error\"").unwrap();
        assert_eq!(back, LogLevel::Error);
    }

    #[test]
    fn log_level_display() {
        assert_eq!(LogLevel::Trace.to_string(), "trace");
        assert_eq!(LogLevel::Fatal.to_string(), "fatal");
    }

    #[test]
    fn log_level_from_str_lossy() {
        assert_eq!(LogLevel::from_str_lossy("WARN"), LogLevel::Warn);
        assert_eq!(LogLevel::from_str_lossy("warning"), LogLevel::Warn);
        assert_eq!(LogLevel::from_str_lossy("unknown"), LogLevel::Info);
    }

    #[test]
    fn log_level_from_tracing() {
        assert_eq!(
            LogLevel::from_tracing(&tracing::Level::ERROR),
            LogLevel::Error
        );
        assert_eq!(
            LogLevel::from_tracing(&tracing::Level::TRACE),
            LogLevel::Trace
        );
    }
}
