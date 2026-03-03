//! # tron-worktree
//!
//! Git worktree isolation for parallel agent sessions.
//!
//! Every session in a git repo gets its own worktree automatically.
//! Parallel sessions produce parallel branches. The user's working
//! tree is never touched. Branches are preserved after session end.
//!
//! ## Crate Boundaries
//!
//! Depends on `tron-events`, `tron-settings`.
//! Does NOT depend on `tron-runtime` or `tron-llm` — the coordinator
//! is injected into runtime from the binary crate.

#[allow(unused_results)]
pub mod coordinator;
#[allow(unused_results)]
pub mod errors;
#[allow(unused_results)]
pub mod git;
#[allow(unused_results)]
pub mod isolation;
#[allow(unused_results)]
pub mod lifecycle;
#[allow(unused_results)]
pub mod merge;
#[allow(unused_results)]
pub mod recovery;
#[allow(unused_results)]
pub mod types;

pub use coordinator::{WorktreeCoordinator, count_diff_stats, split_diff_by_file};
pub use errors::WorktreeError;
pub use types::{
    AcquireResult, CommitEntry, CommitResult, CommittedDiffResult, CommittedFileEntry, DiffSummary,
    IsolationMode, MergeResult, MergeStrategy, ReleaseInfo, SessionBranchInfo, WorktreeConfig,
    WorktreeInfo, WorktreeStatus,
};
