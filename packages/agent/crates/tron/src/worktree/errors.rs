//! Worktree error types.

/// Errors from worktree operations.
#[derive(Debug, thiserror::Error)]
pub enum WorktreeError {
    /// Git command failed.
    #[error("git error: {0}")]
    Git(String),

    /// Git command timed out.
    #[error("git command timed out after {0}ms")]
    Timeout(u64),

    /// Not a git repository.
    #[error("not a git repository: {0}")]
    NotGitRepo(String),

    /// Worktree not found for session.
    #[error("no worktree for session: {0}")]
    NotFound(String),

    /// Branch already exists.
    #[error("branch already exists: {0}")]
    BranchExists(String),

    /// Event store error.
    #[error("event store: {0}")]
    EventStore(String),

    /// I/O error.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

impl From<crate::events::errors::EventStoreError> for WorktreeError {
    fn from(e: crate::events::errors::EventStoreError) -> Self {
        Self::EventStore(e.to_string())
    }
}

/// Worktree result type.
pub type Result<T> = std::result::Result<T, WorktreeError>;
