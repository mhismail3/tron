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

    /// Worktree not found for session. Carries the session id so callers
    /// don't have to thread it through a parallel parameter when mapping
    /// the error to a user-facing code.
    #[error("no worktree for session: {session_id}")]
    NotFound {
        /// Session id with no live worktree (or no working directory at all).
        session_id: String,
    },

    /// Branch already exists.
    #[error("branch already exists: {0}")]
    BranchExists(String),

    /// Branch is currently active (has a worktree).
    #[error("branch is active: {0}")]
    BranchActive(String),

    /// Remote authentication failed (e.g. SSH key rejected, HTTPS 401).
    #[error("git authentication failed: {0}")]
    AuthFailure(String),

    /// Remote network operation timed out or host unreachable.
    #[error("git network error: {0}")]
    NetworkTimeout(String),

    /// Push rejected because the upstream ref moved (non-fast-forward).
    #[error("push rejected: non-fast-forward — {0}")]
    NonFastForward(String),

    /// No remote is configured for the operation (e.g. `git push` without
    /// `origin`).
    #[error("no remote configured: {0}")]
    NoRemoteConfigured(String),

    /// Operation was refused because the target branch is protected.
    #[error("protected branch: {0}")]
    ProtectedBranch(String),

    /// Operation was refused because the working tree has uncommitted
    /// changes and the operation cannot safely proceed.
    #[error("dirty working tree: {0}")]
    DirtyWorkingTree(String),

    /// Merge produced conflicts that must be resolved before the operation
    /// can proceed (e.g. before `finalize_session` re-branches). Carries the
    /// conflicted-file count so callers can surface it without re-querying
    /// the worktree.
    #[error("merge has conflicts ({0} file(s)); resolve first")]
    MergeConflicts(usize),

    /// No merge is in progress for the session (e.g. `merge_context`,
    /// `continue_merge`, `abort_merge` invoked on a clean worktree).
    #[error("session has no pending merge")]
    NoPendingMerge,

    /// Operation refused because the session already has a pending merge
    /// — callers must resolve or abort it first.
    #[error("session already has a pending merge; resolve or abort it first")]
    PendingMergeExists,

    /// `rebase_on_main` was called without a `main_branch` override and
    /// the session's `info.base_branch` is unset — nothing to rebase onto.
    #[error("session has no base branch; pass `mainBranch` explicitly")]
    MissingBaseBranch,

    /// A ref the caller named (e.g. `mainBranch`) could not be resolved
    /// to a commit.
    #[error("ref not found: {0}")]
    RefNotFound(String),

    /// Operation refused because the session's worktree is in an
    /// unexpected state (detached HEAD, branch equals base, …).
    #[error("invalid session state: {0}")]
    InvalidSessionState(String),

    /// Event store error.
    #[error("event store: {0}")]
    EventStore(String),

    /// I/O error.
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

impl From<crate::domains::session::event_store::errors::EventStoreError> for WorktreeError {
    fn from(e: crate::domains::session::event_store::errors::EventStoreError) -> Self {
        Self::EventStore(e.to_string())
    }
}

/// Worktree result type.
pub type Result<T> = std::result::Result<T, WorktreeError>;
