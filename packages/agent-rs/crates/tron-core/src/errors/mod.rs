//! Error hierarchy for the Tron agent.
//!
//! Provides a structured error type system built on [`thiserror`]:
//!
//! - [`TronError`]: Top-level enum covering all error domains
//! - [`SessionError`]: Session lifecycle failures (create, resume, fork, run)
//! - [`PersistenceError`]: Database/storage errors with table and operation context
//! - [`ProviderError`]: LLM provider errors with status code and retry info
//! - [`ToolError`]: Tool execution failures with tool name and call ID
//! - [`ErrorCollector`]: Accumulates errors from fire-and-forget operations
//!
//! The error parsing utilities in [`parse`] classify raw error strings into
//! categories. The RPC error types in [`rpc`] provide wire-format error codes.

pub mod parse;
pub mod rpc;

use std::collections::HashMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::errors::parse::{ErrorCategory, ErrorSeverity, parse_error};

// ─────────────────────────────────────────────────────────────────────────────
// TronError — top-level error enum
// ─────────────────────────────────────────────────────────────────────────────

/// Top-level error type for the Tron agent.
///
/// Each variant carries domain-specific context. All variants can be
/// classified by [`ErrorCategory`] and [`ErrorSeverity`] for logging
/// and retry decisions.
#[derive(Debug, Error)]
pub enum TronError {
    /// Session lifecycle error.
    #[error("{0}")]
    Session(#[from] SessionError),

    /// Database / storage error.
    #[error("{0}")]
    Persistence(#[from] PersistenceError),

    /// LLM provider error.
    #[error("{0}")]
    Provider(#[from] ProviderError),

    /// Tool execution error.
    #[error("{0}")]
    Tool(#[from] ToolError),

    /// RPC handler error.
    #[error("{0}")]
    Rpc(#[from] RpcHandlerError),

    /// Generic internal error with structured context.
    #[error("[{code}] {message}")]
    Internal {
        /// Machine-readable error code.
        code: String,
        /// Human-readable message.
        message: String,
        /// Error category.
        category: ErrorCategory,
        /// Error severity.
        severity: ErrorSeverity,
        /// Structured context for debugging.
        context: HashMap<String, serde_json::Value>,
        /// Original error source.
        #[source]
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
    },
}

impl TronError {
    /// Create a `TronError` from an arbitrary error string.
    ///
    /// Parses the string to determine category and severity.
    #[must_use]
    pub fn from_message(message: &str) -> Self {
        let parsed = parse_error(message);
        Self::Internal {
            code: parsed.category.to_string().to_uppercase(),
            message: parsed.message,
            category: parsed.category,
            severity: if parsed.is_retryable {
                ErrorSeverity::Transient
            } else {
                ErrorSeverity::Error
            },
            context: HashMap::new(),
            source: None,
        }
    }

    /// Create an internal error with a code and message.
    #[must_use]
    pub fn internal(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self::Internal {
            code: code.into(),
            message: message.into(),
            category: ErrorCategory::Unknown,
            severity: ErrorSeverity::Error,
            context: HashMap::new(),
            source: None,
        }
    }

    /// Error category for classification.
    #[must_use]
    pub fn category(&self) -> ErrorCategory {
        match self {
            Self::Session(e) => e.category,
            Self::Provider(e) => e.category,
            Self::Internal { category, .. } => *category,
            Self::Persistence(_) | Self::Tool(_) | Self::Rpc(_) => ErrorCategory::Unknown,
        }
    }

    /// Error severity level.
    #[must_use]
    pub fn severity(&self) -> ErrorSeverity {
        match self {
            Self::Session(e) => e.severity,
            Self::Persistence(e) => e.severity,
            Self::Provider(e) => {
                if e.retryable {
                    ErrorSeverity::Transient
                } else {
                    ErrorSeverity::Error
                }
            }
            Self::Tool(e) => e.severity,
            Self::Rpc(_) => ErrorSeverity::Error,
            Self::Internal { severity, .. } => *severity,
        }
    }

    /// Whether this error is retryable.
    #[must_use]
    pub fn is_retryable(&self) -> bool {
        matches!(
            self.category(),
            ErrorCategory::RateLimit | ErrorCategory::Network | ErrorCategory::Server
        )
    }

    /// Machine-readable error code.
    #[must_use]
    pub fn code(&self) -> &str {
        match self {
            Self::Session(e) => &e.code,
            Self::Persistence(e) => &e.code,
            Self::Provider(e) => &e.code,
            Self::Tool(e) => &e.code,
            Self::Rpc(e) => &e.code,
            Self::Internal { code, .. } => code,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SessionError
// ─────────────────────────────────────────────────────────────────────────────

/// Session lifecycle operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionOperation {
    /// Creating a new session.
    Create,
    /// Resuming an existing session.
    Resume,
    /// Forking a session.
    Fork,
    /// Running the agent loop.
    Run,
    /// Interrupting a running session.
    Interrupt,
    /// Closing a session.
    Close,
}

impl fmt::Display for SessionOperation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Create => write!(f, "create"),
            Self::Resume => write!(f, "resume"),
            Self::Fork => write!(f, "fork"),
            Self::Run => write!(f, "run"),
            Self::Interrupt => write!(f, "interrupt"),
            Self::Close => write!(f, "close"),
        }
    }
}

/// Session lifecycle error.
#[derive(Debug, Error)]
#[error("Session {operation} failed for {session_id}: {message}")]
pub struct SessionError {
    /// Session ID.
    pub session_id: String,
    /// Operation that failed.
    pub operation: SessionOperation,
    /// Human-readable message.
    pub message: String,
    /// Machine-readable error code.
    pub code: String,
    /// Error category.
    pub category: ErrorCategory,
    /// Error severity.
    pub severity: ErrorSeverity,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl SessionError {
    /// Create a new session error.
    #[must_use]
    pub fn new(
        session_id: impl Into<String>,
        operation: SessionOperation,
        message: impl Into<String>,
    ) -> Self {
        let op_upper = operation.to_string().to_uppercase();
        Self {
            session_id: session_id.into(),
            operation,
            message: message.into(),
            code: format!("SESSION_{op_upper}_ERROR"),
            category: ErrorCategory::Unknown,
            severity: ErrorSeverity::Error,
            source: None,
        }
    }

    /// Set the error cause.
    #[must_use]
    pub fn with_source(mut self, source: impl std::error::Error + Send + Sync + 'static) -> Self {
        self.source = Some(Box::new(source));
        self
    }

    /// Set the error severity.
    #[must_use]
    pub fn with_severity(mut self, severity: ErrorSeverity) -> Self {
        self.severity = severity;
        self
    }

    /// Set a custom error code.
    #[must_use]
    pub fn with_code(mut self, code: impl Into<String>) -> Self {
        self.code = code.into();
        self
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PersistenceError
// ─────────────────────────────────────────────────────────────────────────────

/// Database operation kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PersistenceOperation {
    /// Reading from the store.
    Read,
    /// Writing to the store.
    Write,
    /// Deleting from the store.
    Delete,
    /// Querying the store.
    Query,
}

impl fmt::Display for PersistenceOperation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read => write!(f, "read"),
            Self::Write => write!(f, "write"),
            Self::Delete => write!(f, "delete"),
            Self::Query => write!(f, "query"),
        }
    }
}

/// Database / storage persistence error.
#[derive(Debug, Error)]
#[error("Persistence {operation} failed on {table}: {message}")]
pub struct PersistenceError {
    /// Table or store that failed.
    pub table: String,
    /// Operation that failed.
    pub operation: PersistenceOperation,
    /// Human-readable message.
    pub message: String,
    /// Machine-readable error code.
    pub code: String,
    /// Error severity.
    pub severity: ErrorSeverity,
    /// Sanitized query for debugging.
    pub query: Option<String>,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl PersistenceError {
    /// Create a new persistence error.
    #[must_use]
    pub fn new(
        table: impl Into<String>,
        operation: PersistenceOperation,
        message: impl Into<String>,
    ) -> Self {
        let op_upper = operation.to_string().to_uppercase();
        Self {
            table: table.into(),
            operation,
            message: message.into(),
            code: format!("PERSISTENCE_{op_upper}_ERROR"),
            severity: ErrorSeverity::Error,
            query: None,
            source: None,
        }
    }

    /// Set the error cause.
    #[must_use]
    pub fn with_source(mut self, source: impl std::error::Error + Send + Sync + 'static) -> Self {
        self.source = Some(Box::new(source));
        self
    }

    /// Set the sanitized query for debugging.
    #[must_use]
    pub fn with_query(mut self, query: impl Into<String>) -> Self {
        self.query = Some(query.into());
        self
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ProviderError
// ─────────────────────────────────────────────────────────────────────────────

/// LLM provider identifier.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderName {
    /// Anthropic / Claude.
    Anthropic,
    /// `OpenAI`.
    Openai,
    /// Google / Gemini.
    Google,
    /// Unknown provider.
    Unknown,
}

impl fmt::Display for ProviderName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Anthropic => write!(f, "anthropic"),
            Self::Openai => write!(f, "openai"),
            Self::Google => write!(f, "google"),
            Self::Unknown => write!(f, "unknown"),
        }
    }
}

/// Rate limit information from a provider error.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RateLimitInfo {
    /// Milliseconds to wait before retrying.
    pub retry_after_ms: u64,
    /// Provider-reported rate limit, if available.
    pub limit: Option<u64>,
}

/// LLM provider error.
#[derive(Debug, Error)]
#[error("Provider {provider} error ({model}): {message}")]
pub struct ProviderError {
    /// Provider name.
    pub provider: ProviderName,
    /// Model being used.
    pub model: String,
    /// Human-readable message.
    pub message: String,
    /// Machine-readable error code.
    pub code: String,
    /// Error category.
    pub category: ErrorCategory,
    /// HTTP status code if applicable.
    pub status_code: Option<u16>,
    /// Whether this error is retryable.
    pub retryable: bool,
    /// Rate limit info if applicable.
    pub rate_limit_info: Option<RateLimitInfo>,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl ProviderError {
    /// Create a new provider error.
    #[must_use]
    pub fn new(
        provider: ProviderName,
        model: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        let provider_upper = provider.to_string().to_uppercase();
        Self {
            provider,
            model: model.into(),
            message: message.into(),
            code: format!("PROVIDER_{provider_upper}_ERROR"),
            category: ErrorCategory::Unknown,
            status_code: None,
            retryable: false,
            rate_limit_info: None,
            source: None,
        }
    }

    /// Set the HTTP status code and infer category.
    #[must_use]
    pub fn with_status(mut self, status: u16) -> Self {
        self.status_code = Some(status);
        self.category = match status {
            401 => ErrorCategory::Authentication,
            403 => ErrorCategory::Authorization,
            429 => ErrorCategory::RateLimit,
            400 => ErrorCategory::InvalidRequest,
            s if s >= 500 => ErrorCategory::Server,
            _ => self.category,
        };
        self.retryable = matches!(
            self.category,
            ErrorCategory::RateLimit | ErrorCategory::Server
        );
        self
    }

    /// Set the retryable flag explicitly.
    #[must_use]
    pub fn with_retryable(mut self, retryable: bool) -> Self {
        self.retryable = retryable;
        self
    }

    /// Set the rate limit info.
    #[must_use]
    pub fn with_rate_limit(mut self, info: RateLimitInfo) -> Self {
        self.rate_limit_info = Some(info);
        self
    }

    /// Set the error cause.
    #[must_use]
    pub fn with_source(mut self, source: impl std::error::Error + Send + Sync + 'static) -> Self {
        self.source = Some(Box::new(source));
        self
    }

    /// Create from an error string, parsing it for category and retry info.
    #[must_use]
    pub fn from_error_string(
        provider: ProviderName,
        model: impl Into<String>,
        error_str: &str,
        status_code: Option<u16>,
    ) -> Self {
        let parsed = parse_error(error_str);
        let mut err = Self::new(provider, model, parsed.message);
        err.code = parsed.category.to_string().to_uppercase();
        err.category = parsed.category;
        err.retryable = parsed.is_retryable;
        if let Some(status) = status_code {
            err.status_code = Some(status);
        }
        err
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ToolError
// ─────────────────────────────────────────────────────────────────────────────

/// Tool execution error.
#[derive(Debug, Error)]
#[error("Tool {tool_name} (call {tool_call_id}) failed: {message}")]
pub struct ToolError {
    /// Tool name.
    pub tool_name: String,
    /// Tool call ID.
    pub tool_call_id: String,
    /// Human-readable message.
    pub message: String,
    /// Machine-readable error code.
    pub code: String,
    /// Error severity.
    pub severity: ErrorSeverity,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl ToolError {
    /// Create a new tool error.
    #[must_use]
    pub fn new(
        tool_name: impl Into<String>,
        tool_call_id: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        let name: String = tool_name.into();
        let code = format!("TOOL_{}_ERROR", name.to_uppercase());
        Self {
            tool_name: name,
            tool_call_id: tool_call_id.into(),
            message: message.into(),
            code,
            severity: ErrorSeverity::Error,
            source: None,
        }
    }

    /// Set the error cause.
    #[must_use]
    pub fn with_source(mut self, source: impl std::error::Error + Send + Sync + 'static) -> Self {
        self.source = Some(Box::new(source));
        self
    }

    /// Set the error severity.
    #[must_use]
    pub fn with_severity(mut self, severity: ErrorSeverity) -> Self {
        self.severity = severity;
        self
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// RpcHandlerError
// ─────────────────────────────────────────────────────────────────────────────

/// RPC handler error for converting response errors to typed errors.
#[derive(Debug, Error)]
#[error("[{code}] {message}")]
pub struct RpcHandlerError {
    /// Machine-readable error code.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl RpcHandlerError {
    /// Create a new RPC handler error.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            code: "RPC_ERROR".to_owned(),
            message: message.into(),
            source: None,
        }
    }

    /// Set a custom error code.
    #[must_use]
    pub fn with_code(mut self, code: impl Into<String>) -> Self {
        self.code = code.into();
        self
    }

    /// Create from an RPC error response.
    #[must_use]
    pub fn from_response(message: impl Into<String>, code: Option<&str>) -> Self {
        Self {
            code: code.unwrap_or("RPC_ERROR").to_owned(),
            message: message.into(),
            source: None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ErrorCollector
// ─────────────────────────────────────────────────────────────────────────────

/// Collects errors from fire-and-forget operations without losing them.
///
/// Useful when running multiple tasks concurrently where each can fail
/// independently, but you don't want to abort on the first failure.
///
/// # Example
///
/// ```
/// use tron_core::errors::ErrorCollector;
///
/// let mut collector = ErrorCollector::new();
/// collector.collect("task 1 failed");
/// collector.collect("task 2 failed");
/// assert_eq!(collector.count(), 2);
///
/// let errors = collector.flush();
/// assert_eq!(errors.len(), 2);
/// assert_eq!(collector.count(), 0);
/// ```
#[derive(Debug, Default)]
pub struct ErrorCollector {
    errors: Vec<TronError>,
}

impl ErrorCollector {
    /// Create a new empty collector.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Collect an error, wrapping it in [`TronError`] if needed.
    pub fn collect(&mut self, error: impl Into<String>) {
        self.errors.push(TronError::from_message(&error.into()));
    }

    /// Collect an existing [`TronError`].
    pub fn collect_error(&mut self, error: TronError) {
        self.errors.push(error);
    }

    /// Whether any errors have been collected.
    #[must_use]
    pub fn has_errors(&self) -> bool {
        !self.errors.is_empty()
    }

    /// Number of collected errors.
    #[must_use]
    pub fn count(&self) -> usize {
        self.errors.len()
    }

    /// View collected errors.
    #[must_use]
    pub fn errors(&self) -> &[TronError] {
        &self.errors
    }

    /// Get and clear all collected errors.
    pub fn flush(&mut self) -> Vec<TronError> {
        std::mem::take(&mut self.errors)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility functions
// ─────────────────────────────────────────────────────────────────────────────

/// Check if an error has a specific error code.
///
/// Works with [`TronError`] and its sub-error types.
#[must_use]
pub fn has_error_code(error: &TronError, code: &str) -> bool {
    error.code() == code
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // -- TronError --

    #[test]
    fn tron_error_from_message_auth() {
        let err = TronError::from_message("401 unauthorized");
        assert_eq!(err.category(), ErrorCategory::Authentication);
        assert!(!err.is_retryable());
    }

    #[test]
    fn tron_error_from_message_rate_limit() {
        let err = TronError::from_message("429 rate limit exceeded");
        assert_eq!(err.category(), ErrorCategory::RateLimit);
        assert!(err.is_retryable());
    }

    #[test]
    fn tron_error_from_message_network() {
        let err = TronError::from_message("ECONNREFUSED");
        assert_eq!(err.category(), ErrorCategory::Network);
        assert!(err.is_retryable());
    }

    #[test]
    fn tron_error_from_message_unknown() {
        let err = TronError::from_message("something weird happened");
        assert_eq!(err.category(), ErrorCategory::Unknown);
        assert!(!err.is_retryable());
    }

    #[test]
    fn tron_error_internal() {
        let err = TronError::internal("MY_CODE", "my message");
        assert_eq!(err.code(), "MY_CODE");
        assert_eq!(err.category(), ErrorCategory::Unknown);
        assert_eq!(err.severity(), ErrorSeverity::Error);
        assert!(err.to_string().contains("MY_CODE"));
        assert!(err.to_string().contains("my message"));
    }

    #[test]
    fn tron_error_from_session() {
        let session_err = SessionError::new("sess-1", SessionOperation::Create, "failed");
        let err = TronError::from(session_err);
        assert!(err.to_string().contains("sess-1"));
        assert_eq!(err.code(), "SESSION_CREATE_ERROR");
    }

    #[test]
    fn tron_error_from_persistence() {
        let persistence_err =
            PersistenceError::new("events", PersistenceOperation::Write, "disk full");
        let err = TronError::from(persistence_err);
        assert!(err.to_string().contains("events"));
        assert_eq!(err.code(), "PERSISTENCE_WRITE_ERROR");
    }

    #[test]
    fn tron_error_from_provider() {
        let provider_err =
            ProviderError::new(ProviderName::Anthropic, "claude-opus-4-6", "overloaded")
                .with_status(529);
        let err = TronError::from(provider_err);
        assert!(err.to_string().contains("anthropic"));
        assert!(err.is_retryable());
    }

    #[test]
    fn tron_error_from_tool() {
        let tool_err = ToolError::new("bash", "call-1", "timeout");
        let err = TronError::from(tool_err);
        assert!(err.to_string().contains("bash"));
        assert_eq!(err.code(), "TOOL_BASH_ERROR");
    }

    #[test]
    fn tron_error_from_rpc_handler() {
        let rpc_err = RpcHandlerError::new("not found").with_code("SESSION_NOT_FOUND");
        let err = TronError::from(rpc_err);
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // -- SessionError --

    #[test]
    fn session_error_create() {
        let err = SessionError::new("sess-1", SessionOperation::Create, "max sessions reached");
        assert_eq!(err.session_id, "sess-1");
        assert_eq!(err.operation, SessionOperation::Create);
        assert_eq!(err.code, "SESSION_CREATE_ERROR");
        assert!(err.to_string().contains("sess-1"));
        assert!(err.to_string().contains("create"));
    }

    #[test]
    fn session_error_with_custom_code() {
        let err = SessionError::new("sess-1", SessionOperation::Fork, "branch missing")
            .with_code("SESSION_FORK_BRANCH_ERROR");
        assert_eq!(err.code, "SESSION_FORK_BRANCH_ERROR");
    }

    #[test]
    fn session_error_with_severity() {
        let err = SessionError::new("sess-1", SessionOperation::Run, "interrupted")
            .with_severity(ErrorSeverity::Warning);
        assert_eq!(err.severity, ErrorSeverity::Warning);
    }

    #[test]
    fn session_error_with_source() {
        let cause = std::io::Error::new(std::io::ErrorKind::Other, "disk error");
        let err = SessionError::new("sess-1", SessionOperation::Resume, "database read failed")
            .with_source(cause);
        assert!(err.source.is_some());
    }

    #[test]
    fn session_operation_display() {
        assert_eq!(SessionOperation::Create.to_string(), "create");
        assert_eq!(SessionOperation::Resume.to_string(), "resume");
        assert_eq!(SessionOperation::Fork.to_string(), "fork");
        assert_eq!(SessionOperation::Run.to_string(), "run");
        assert_eq!(SessionOperation::Interrupt.to_string(), "interrupt");
        assert_eq!(SessionOperation::Close.to_string(), "close");
    }

    // -- PersistenceError --

    #[test]
    fn persistence_error_write() {
        let err = PersistenceError::new("events", PersistenceOperation::Write, "disk full");
        assert_eq!(err.table, "events");
        assert_eq!(err.operation, PersistenceOperation::Write);
        assert_eq!(err.code, "PERSISTENCE_WRITE_ERROR");
        assert!(err.to_string().contains("events"));
    }

    #[test]
    fn persistence_error_with_query() {
        let err = PersistenceError::new("sessions", PersistenceOperation::Query, "timeout")
            .with_query("SELECT * FROM sessions WHERE ...");
        assert_eq!(
            err.query.as_deref(),
            Some("SELECT * FROM sessions WHERE ...")
        );
    }

    #[test]
    fn persistence_error_with_source() {
        let cause = std::io::Error::new(std::io::ErrorKind::Other, "sqlite busy");
        let err = PersistenceError::new("events", PersistenceOperation::Read, "locked")
            .with_source(cause);
        assert!(err.source.is_some());
    }

    #[test]
    fn persistence_operation_display() {
        assert_eq!(PersistenceOperation::Read.to_string(), "read");
        assert_eq!(PersistenceOperation::Write.to_string(), "write");
        assert_eq!(PersistenceOperation::Delete.to_string(), "delete");
        assert_eq!(PersistenceOperation::Query.to_string(), "query");
    }

    // -- ProviderError --

    #[test]
    fn provider_error_basic() {
        let err = ProviderError::new(ProviderName::Anthropic, "claude-opus-4-6", "server error");
        assert_eq!(err.provider, ProviderName::Anthropic);
        assert_eq!(err.model, "claude-opus-4-6");
        assert_eq!(err.code, "PROVIDER_ANTHROPIC_ERROR");
        assert!(!err.retryable);
    }

    #[test]
    fn provider_error_with_401_status() {
        let err = ProviderError::new(ProviderName::Anthropic, "claude-opus-4-6", "unauthorized")
            .with_status(401);
        assert_eq!(err.category, ErrorCategory::Authentication);
        assert!(!err.retryable);
    }

    #[test]
    fn provider_error_with_429_status() {
        let err =
            ProviderError::new(ProviderName::Openai, "gpt-4", "rate limited").with_status(429);
        assert_eq!(err.category, ErrorCategory::RateLimit);
        assert!(err.retryable);
    }

    #[test]
    fn provider_error_with_500_status() {
        let err = ProviderError::new(ProviderName::Google, "gemini-2.0", "internal error")
            .with_status(500);
        assert_eq!(err.category, ErrorCategory::Server);
        assert!(err.retryable);
    }

    #[test]
    fn provider_error_with_rate_limit_info() {
        let err = ProviderError::new(ProviderName::Anthropic, "claude-opus-4-6", "rate limited")
            .with_status(429)
            .with_rate_limit(RateLimitInfo {
                retry_after_ms: 5000,
                limit: Some(100),
            });
        assert!(err.retryable);
        let info = err.rate_limit_info.as_ref().unwrap();
        assert_eq!(info.retry_after_ms, 5000);
        assert_eq!(info.limit, Some(100));
    }

    #[test]
    fn provider_error_from_error_string() {
        let err = ProviderError::from_error_string(
            ProviderName::Anthropic,
            "claude-opus-4-6",
            "429 rate limit exceeded",
            Some(429),
        );
        assert_eq!(err.category, ErrorCategory::RateLimit);
        assert!(err.retryable);
        assert_eq!(err.status_code, Some(429));
    }

    #[test]
    fn provider_error_explicit_retryable() {
        let err =
            ProviderError::new(ProviderName::Openai, "gpt-4", "temporary").with_retryable(true);
        assert!(err.retryable);
    }

    #[test]
    fn provider_name_display() {
        assert_eq!(ProviderName::Anthropic.to_string(), "anthropic");
        assert_eq!(ProviderName::Openai.to_string(), "openai");
        assert_eq!(ProviderName::Google.to_string(), "google");
        assert_eq!(ProviderName::Unknown.to_string(), "unknown");
    }

    // -- ToolError --

    #[test]
    fn tool_error_basic() {
        let err = ToolError::new("bash", "call-1", "command timed out");
        assert_eq!(err.tool_name, "bash");
        assert_eq!(err.tool_call_id, "call-1");
        assert_eq!(err.code, "TOOL_BASH_ERROR");
        assert!(err.to_string().contains("bash"));
        assert!(err.to_string().contains("call-1"));
    }

    #[test]
    fn tool_error_with_severity() {
        let err = ToolError::new("read", "call-2", "file not found")
            .with_severity(ErrorSeverity::Warning);
        assert_eq!(err.severity, ErrorSeverity::Warning);
    }

    #[test]
    fn tool_error_with_source() {
        let cause = std::io::Error::new(std::io::ErrorKind::NotFound, "no such file");
        let err = ToolError::new("read", "call-2", "file not found").with_source(cause);
        assert!(err.source.is_some());
    }

    // -- RpcHandlerError --

    #[test]
    fn rpc_handler_error_basic() {
        let err = RpcHandlerError::new("session not found");
        assert_eq!(err.code, "RPC_ERROR");
        assert_eq!(err.message, "session not found");
    }

    #[test]
    fn rpc_handler_error_with_code() {
        let err = RpcHandlerError::new("not found").with_code("SESSION_NOT_FOUND");
        assert_eq!(err.code, "SESSION_NOT_FOUND");
    }

    #[test]
    fn rpc_handler_error_from_response() {
        let err = RpcHandlerError::from_response("bad request", Some("INVALID_PARAMS"));
        assert_eq!(err.code, "INVALID_PARAMS");
        assert_eq!(err.message, "bad request");
    }

    #[test]
    fn rpc_handler_error_from_response_no_code() {
        let err = RpcHandlerError::from_response("unknown error", None);
        assert_eq!(err.code, "RPC_ERROR");
    }

    #[test]
    fn rpc_handler_error_display() {
        let err = RpcHandlerError::new("test error").with_code("MY_CODE");
        assert_eq!(err.to_string(), "[MY_CODE] test error");
    }

    // -- ErrorCollector --

    #[test]
    fn error_collector_empty() {
        let collector = ErrorCollector::new();
        assert!(!collector.has_errors());
        assert_eq!(collector.count(), 0);
        assert!(collector.errors().is_empty());
    }

    #[test]
    fn error_collector_collect_strings() {
        let mut collector = ErrorCollector::new();
        collector.collect("task 1 failed");
        collector.collect("task 2 failed");
        assert!(collector.has_errors());
        assert_eq!(collector.count(), 2);
    }

    #[test]
    fn error_collector_collect_error() {
        let mut collector = ErrorCollector::new();
        collector.collect_error(TronError::internal("TEST", "test error"));
        assert_eq!(collector.count(), 1);
        assert_eq!(collector.errors()[0].code(), "TEST");
    }

    #[test]
    fn error_collector_flush() {
        let mut collector = ErrorCollector::new();
        collector.collect("error 1");
        collector.collect("error 2");
        let errors = collector.flush();
        assert_eq!(errors.len(), 2);
        assert_eq!(collector.count(), 0);
        assert!(!collector.has_errors());
    }

    #[test]
    fn error_collector_default() {
        let collector = ErrorCollector::default();
        assert!(!collector.has_errors());
    }

    // -- has_error_code --

    #[test]
    fn has_error_code_matches() {
        let err = TronError::internal("MY_CODE", "test");
        assert!(has_error_code(&err, "MY_CODE"));
    }

    #[test]
    fn has_error_code_no_match() {
        let err = TronError::internal("MY_CODE", "test");
        assert!(!has_error_code(&err, "OTHER_CODE"));
    }

    #[test]
    fn has_error_code_from_session() {
        let err = TronError::from(SessionError::new("s1", SessionOperation::Create, "failed"));
        assert!(has_error_code(&err, "SESSION_CREATE_ERROR"));
    }

    // -- Error trait impls --

    #[test]
    fn session_error_is_std_error() {
        let err = SessionError::new("s1", SessionOperation::Run, "boom");
        let _: &dyn std::error::Error = &err;
    }

    #[test]
    fn persistence_error_is_std_error() {
        let err = PersistenceError::new("t", PersistenceOperation::Read, "err");
        let _: &dyn std::error::Error = &err;
    }

    #[test]
    fn provider_error_is_std_error() {
        let err = ProviderError::new(ProviderName::Unknown, "m", "err");
        let _: &dyn std::error::Error = &err;
    }

    #[test]
    fn tool_error_is_std_error() {
        let err = ToolError::new("t", "c", "err");
        let _: &dyn std::error::Error = &err;
    }

    #[test]
    fn rpc_handler_error_is_std_error() {
        let err = RpcHandlerError::new("err");
        let _: &dyn std::error::Error = &err;
    }

    #[test]
    fn tron_error_is_std_error() {
        let err = TronError::internal("C", "m");
        let _: &dyn std::error::Error = &err;
    }

    // -- Severity and category propagation --

    #[test]
    fn tron_error_severity_from_session() {
        let session_err = SessionError::new("s1", SessionOperation::Run, "warn")
            .with_severity(ErrorSeverity::Warning);
        let err = TronError::from(session_err);
        assert_eq!(err.severity(), ErrorSeverity::Warning);
    }

    #[test]
    fn tron_error_severity_from_persistence() {
        let persistence_err = PersistenceError::new("events", PersistenceOperation::Write, "err");
        let err = TronError::from(persistence_err);
        assert_eq!(err.severity(), ErrorSeverity::Error);
    }

    #[test]
    fn tron_error_severity_from_provider_retryable() {
        let provider_err =
            ProviderError::new(ProviderName::Anthropic, "model", "overloaded").with_retryable(true);
        let err = TronError::from(provider_err);
        assert_eq!(err.severity(), ErrorSeverity::Transient);
    }

    #[test]
    fn tron_error_severity_from_tool() {
        let tool_err = ToolError::new("bash", "c1", "timeout").with_severity(ErrorSeverity::Fatal);
        let err = TronError::from(tool_err);
        assert_eq!(err.severity(), ErrorSeverity::Fatal);
    }

    #[test]
    fn tron_error_category_from_provider_status() {
        let provider_err =
            ProviderError::new(ProviderName::Openai, "gpt-4", "forbidden").with_status(403);
        let err = TronError::from(provider_err);
        assert_eq!(err.category(), ErrorCategory::Authorization);
    }
}
