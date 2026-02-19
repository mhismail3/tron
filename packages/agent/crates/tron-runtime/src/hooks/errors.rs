//! Hook error types.

use thiserror::Error;

/// Errors that can occur during hook execution.
#[derive(Debug, Error)]
pub enum HookError {
    /// Hook execution timed out.
    #[error("Hook timed out after {timeout_ms}ms: {name}")]
    Timeout {
        /// Hook name that timed out.
        name: String,
        /// Configured timeout in milliseconds.
        timeout_ms: u64,
    },

    /// Hook handler returned an error.
    #[error("Hook handler error in '{name}': {message}")]
    HandlerError {
        /// Hook name.
        name: String,
        /// Error message from handler.
        message: String,
    },

    /// Hook registration error (e.g., duplicate name).
    #[error("Registration error: {0}")]
    Registration(String),

    /// Hook discovery error.
    #[error("Discovery error: {0}")]
    Discovery(String),

    /// Generic internal error.
    #[error("{0}")]
    Internal(String),
}
