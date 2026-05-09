//! Import error types.

use std::path::PathBuf;

/// Errors that can occur during Claude Code session import.
#[derive(Debug, thiserror::Error)]
#[allow(missing_docs)]
pub enum ImportError {
    #[error("IO error reading {}: {source}", path.display())]
    Io {
        path: PathBuf,
        source: std::io::Error,
    },

    #[error("Session file not found: {}", path.display())]
    SessionNotFound { path: PathBuf },

    #[error("Session already imported as Tron session {tron_session_id}")]
    AlreadyImported { tron_session_id: String },

    #[error("Database error: {0}")]
    Database(#[from] crate::domains::session::event_store::errors::EventStoreError),

    #[error("Empty session: no importable records after parsing")]
    EmptySession,

    #[error("No Claude Code directory found at {}", path.display())]
    NoClaudeDirectory { path: PathBuf },
}
