//! Memory error types.
//!
//! All memory errors are non-fatal — they are logged and swallowed by the
//! [`MemoryManager`](crate::manager::MemoryManager). Memory operations
//! should never crash a session.

use thiserror::Error;

/// Errors from memory operations.
#[derive(Debug, Error)]
pub enum MemoryError {
    /// Compaction execution failed.
    #[error("Compaction failed: {0}")]
    Compaction(String),

    /// Ledger write failed.
    #[error("Ledger write failed: {0}")]
    LedgerWrite(String),

    /// Embedding failed.
    #[error("Embedding failed: {0}")]
    Embedding(String),

    /// Generic internal error.
    #[error("{0}")]
    Internal(String),
}
