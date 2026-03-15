//! # worktree
//!
//! Git worktree isolation for parallel agent sessions.
//!
//! Every session in a git repo gets its own worktree automatically.
//! Parallel sessions produce parallel branches. The user's working
//! tree is never touched. Branches are preserved after session end.
//!
//! ## Module Boundaries
//!
//! Depends on `events`, `settings`.
//! Does NOT depend on `runtime` or `llm` — the coordinator
//! is injected into runtime from `main.rs`.

#[path = "runtime/coordinator.rs"]
pub mod coordinator;
pub mod errors;
#[path = "scm/git.rs"]
pub mod git;
#[path = "scm/isolation.rs"]
pub mod isolation;
#[path = "runtime/lifecycle.rs"]
pub mod lifecycle;
#[path = "scm/merge.rs"]
pub mod merge;
#[path = "runtime/recovery.rs"]
pub mod recovery;
#[path = "model/types.rs"]
pub mod types;

pub use coordinator::{WorktreeCoordinator, count_diff_stats, split_diff_by_file};
pub use errors::WorktreeError;
pub use types::{
    AcquireResult, CommitEntry, CommitResult, CommittedDiffResult, CommittedFileEntry, DiffSummary,
    IsolationMode, MergeResult, MergeStrategy, ReleaseInfo, SessionBranchInfo, WorktreeConfig,
    WorktreeInfo, WorktreeStatus,
};
