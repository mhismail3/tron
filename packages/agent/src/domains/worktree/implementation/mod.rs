//! # worktree
//!
//! Git worktree isolation for parallel agent sessions, plus the full
//! git workflow surface (sync, push, merge + conflict resolution,
//! finalize) that sits on top of it.
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
//!
//! ## Submodules
//!
//! | Module        | Contents |
//! |---------------|----------|
//! | `coordinator` | Top-level orchestrator (`WorktreeCoordinator`) with sync / finalize / push / conflict / repo-lock submodules |
//! | `git`         | `GitExecutor` command catalog with command/remote/state/conflict/parser/error-classification submodules |
//! | `isolation`   | Worktree acquisition / release primitives |
//! | `lifecycle`   | Coordinator's acquire / release hooks |
//! | `sync`        | `sync_main` — FF local main from upstream |
//! | `push`        | `push_branch` with protected-branch rules |
//! | `conflict`    | Conflict state machine (keep / list / resolve / continue / abort) |
//! | `merge`       | `merge_session` (auto-abort) and `finalize_session` (merge + rebranch) |
//! | `recovery`    | Orphan cleanup and crash-recovery reconstruction of pending merges |
//! | `errors`      | `WorktreeError` + typed variants for auth / network / non-FF / protected |
//! | `types`       | Shared result / config / state types (`SyncOutcome`, `PushOutput`, `ConflictedFile`, …) |
//!
//! ## Key invariants
//!
//! 1. `sync_main` never modifies `main` with a dirty repo-root working
//!    tree.
//! 2. `push_branch` never force-pushes to a protected branch unless
//!    `override_protected` is explicitly set.
//! 3. `conflict` state is the on-disk `.git/MERGE_HEAD` / `.git/rebase-merge/`;
//!    `recovery::reconstruct_pending_merge` rebuilds in-memory state from it.
//! 4. `finalize_session` either completes fully (merge commit + new
//!    follow-up branch) or leaves no partial state (no new branch created).
//! 5. `scm::conflict::start_merge_keep_conflicts` is used in BOTH
//!    directions: session → main (finalize flow) and main → session
//!    (rebase_on_main flow). The conflict state machine is direction-
//!    symmetric; only the coordinator layer (and its `MergeOrigin`
//!    discriminator) distinguishes the two callers.
//! 6. `StashPop` is a third `MergeOrigin` — it has no on-disk
//!    `.git/MERGE_HEAD` / `.git/rebase-merge` state; conflicts live in
//!    the index as unmerged entries from a conflicted `git stash pop`.
//!    The coordinator synthesises a `PendingMergeState` (via
//!    `handle_post_stash_pop`) so `listConflicts` / `resolveConflict` /
//!    `continueMerge` / `abortMerge` work uniformly across all three
//!    origins. `continueMerge(StashPop)` drops the stash;
//!    `abortMerge(StashPop)` `git reset --hard HEAD`s the worktree and
//!    preserves the stash on the stack.

#[path = "scm/conflict.rs"]
pub mod conflict;
#[path = "runtime/coordinator/mod.rs"]
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
#[path = "scm/push.rs"]
pub mod push;
#[path = "runtime/recovery.rs"]
pub mod recovery;
#[path = "scm/sync.rs"]
pub mod sync;
#[cfg(test)]
#[path = "scm/test_fixtures.rs"]
pub(crate) mod test_fixtures;
#[path = "model/types.rs"]
pub mod types;

pub use coordinator::{WorktreeCoordinator, count_diff_stats, split_diff_by_file};
pub use errors::WorktreeError;
pub use types::{
    AcquireResult, CommitEntry, CommitOptions, CommitResult, CommittedDiffResult,
    CommittedFileEntry, ConflictKind, ConflictResolution, ConflictedFile, DeferralReason,
    DeleteBranchResult, DiffSummary, FinalizeSessionResult, IsolationMode, MergeOrigin,
    MergeResult, MergeStrategy, PendingMergeState, PruneBranchesResult, PruneFailure, PushOutput,
    RebaseOnMainResult, ReleaseInfo, SessionBranchInfo, SyncBlockReason, SyncOutcome,
    WorktreeConfig, WorktreeInfo, WorktreeStatus,
};
