//! Error hierarchy for the Tron agent.
//!
//! Provides a structured error type system built on [`thiserror`]:
//!
//! - [`TronError`]: Top-level enum covering all error domains
//! - [`SessionError`]: Session lifecycle failures (create, resume, fork, run)
//! - [`PersistenceError`]: Database/storage errors with table and operation context
//! - [`ProviderError`]: LLM provider errors with status code and retry info
//! - [`CapabilityExecutionError`]: Capability invocation failures with capability id and call ID
//! - [`ErrorCollector`]: Accumulates errors from fire-and-forget operations
//!
//! The error parsing utilities in [`parse`] classify raw error strings into
//! categories.

pub mod parse;

use std::collections::HashMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::shared::foundation::errors::parse::{ErrorCategory, ErrorSeverity, parse_error};

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

    /// Capability invocation error.
    #[error("{0}")]
    CapabilityInvocation(#[from] CapabilityExecutionError),

    /// canonical capability function error.
    #[error("{0}")]
    Capability(#[from] CapabilityResponseError),

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
            Self::Persistence(_) | Self::CapabilityInvocation(_) | Self::Capability(_) => {
                ErrorCategory::Unknown
            }
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
            Self::CapabilityInvocation(e) => e.severity,
            Self::Capability(_) => ErrorSeverity::Error,
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
            Self::CapabilityInvocation(e) => &e.code,
            Self::Capability(e) => &e.code,
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

use crate::shared::protocol::messages::Provider;

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
    pub provider: Provider,
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
    pub fn new(provider: Provider, model: impl Into<String>, message: impl Into<String>) -> Self {
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
        provider: Provider,
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
// CapabilityExecutionError
// ─────────────────────────────────────────────────────────────────────────────

/// Capability invocation error.
#[derive(Debug, Error)]
#[error("Capability {capability_id} (invocation {invocation_id}) failed: {message}")]
pub struct CapabilityExecutionError {
    /// Capability name.
    pub capability_id: String,
    /// Capability invocation ID.
    pub invocation_id: String,
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

impl CapabilityExecutionError {
    /// Create a new capability error.
    #[must_use]
    pub fn new(
        capability_id: impl Into<String>,
        invocation_id: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        let name: String = capability_id.into();
        let code = format!("CAPABILITY_{}_ERROR", name.to_uppercase());
        Self {
            capability_id: name,
            invocation_id: invocation_id.into(),
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
// CapabilityResponseError
// ─────────────────────────────────────────────────────────────────────────────

/// canonical capability function error for converting response errors to typed errors.
#[derive(Debug, Error)]
#[error("[{code}] {message}")]
pub struct CapabilityResponseError {
    /// Machine-readable error code.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Original cause.
    #[source]
    pub source: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl CapabilityResponseError {
    /// Create a new canonical capability function error.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            code: "CAPABILITY_ERROR".to_owned(),
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

    /// Create from a capability error response.
    #[must_use]
    pub fn from_response(message: impl Into<String>, code: Option<&str>) -> Self {
        Self {
            code: code.unwrap_or("CAPABILITY_ERROR").to_owned(),
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
/// use crate::shared::foundation::errors::ErrorCollector;
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
mod tests;
