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

/// A stored log entry (from `SQLite`).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    /// Row ID.
    pub id: i64,
    /// ISO 8601 timestamp.
    pub timestamp: String,
    /// Log level.
    pub level: LogLevel,
    /// Numeric level for filtering.
    pub level_num: i32,
    /// Component/module name.
    pub component: String,
    /// Log message.
    pub message: String,
    /// Session identifier (if available).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Workspace identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Event identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_id: Option<String>,
    /// Turn number.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<i64>,
    /// Trace ID for operation correlation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    /// Parent trace ID (for sub-agent correlation).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_trace_id: Option<String>,
    /// Nesting depth (0=root).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub depth: Option<i32>,
    /// Additional structured data (JSON).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
    /// Error message (if error-level).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
    /// Error stack trace.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_stack: Option<String>,
}

/// Options for querying logs.
#[derive(Clone, Debug, Default)]
pub struct LogQueryOptions {
    /// Filter by session ID.
    pub session_id: Option<String>,
    /// Filter by workspace ID.
    pub workspace_id: Option<String>,
    /// Minimum log level (numeric).
    pub min_level: Option<i32>,
    /// Filter by component names.
    pub components: Option<Vec<String>>,
    /// Full-text search query.
    pub search: Option<String>,
    /// Filter by trace ID.
    pub trace_id: Option<String>,
    /// Maximum number of results.
    pub limit: Option<usize>,
    /// Offset for pagination.
    pub offset: Option<usize>,
    /// Sort order (`"asc"` or `"desc"`).
    pub order: Option<String>,
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
        assert_eq!(
            serde_json::to_string(&LogLevel::Warn).unwrap(),
            "\"warn\""
        );
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

    #[test]
    fn log_entry_serde_roundtrip() {
        let entry = LogEntry {
            id: 1,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            level: LogLevel::Info,
            level_num: 30,
            component: "test".to_string(),
            message: "hello".to_string(),
            session_id: Some("sess_123".to_string()),
            workspace_id: None,
            event_id: None,
            turn: Some(1),
            trace_id: None,
            parent_trace_id: None,
            depth: None,
            data: None,
            error_message: None,
            error_stack: None,
        };
        let json = serde_json::to_string(&entry).unwrap();
        let back: LogEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, 1);
        assert_eq!(back.level, LogLevel::Info);
        assert_eq!(back.session_id, Some("sess_123".to_string()));
    }

    #[test]
    fn log_entry_omits_none_fields() {
        let entry = LogEntry {
            id: 1,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            level: LogLevel::Info,
            level_num: 30,
            component: "test".to_string(),
            message: "hello".to_string(),
            session_id: None,
            workspace_id: None,
            event_id: None,
            turn: None,
            trace_id: None,
            parent_trace_id: None,
            depth: None,
            data: None,
            error_message: None,
            error_stack: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert!(json.get("sessionId").is_none());
        assert!(json.get("turn").is_none());
        assert!(json.get("data").is_none());
    }

    #[test]
    fn query_options_default() {
        let opts = LogQueryOptions::default();
        assert!(opts.session_id.is_none());
        assert!(opts.limit.is_none());
    }
}
