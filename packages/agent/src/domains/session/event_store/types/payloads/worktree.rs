//! Worktree event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `worktree.acquired` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeAcquiredPayload {
    /// Worktree path.
    pub path: String,
    /// Branch name.
    pub branch: String,
    /// Base commit hash.
    pub base_commit: String,
    /// Whether the worktree is isolated.
    pub isolated: bool,
    /// Fork source if applicable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forked_from: Option<WorktreeForkSource>,
}

/// Worktree fork source.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeForkSource {
    /// Source session ID.
    pub session_id: String,
    /// Source commit hash.
    pub commit: String,
}

/// Payload for `worktree.commit` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeCommitPayload {
    /// Commit hash.
    pub commit_hash: String,
    /// Commit message.
    pub message: String,
    /// Files changed.
    pub files_changed: Vec<String>,
    /// Lines inserted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub insertions: Option<i64>,
    /// Lines deleted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i64>,
}

/// Payload for `worktree.released` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeReleasedPayload {
    /// Final commit hash.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub final_commit: Option<String>,
    /// Whether the worktree was deleted.
    pub deleted: bool,
    /// Whether the branch was preserved.
    pub branch_preserved: bool,
}

/// Payload for `worktree.merged` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeMergedPayload {
    /// Source branch name.
    pub source_branch: String,
    /// Target branch name.
    pub target_branch: String,
    /// Merge commit hash.
    pub merge_commit: String,
    /// Merge strategy.
    pub strategy: String,
}

/// Payload for `worktree.renamed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeRenamedPayload {
    /// Previous branch name.
    pub old_branch: String,
    /// New branch name.
    pub new_branch: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase-4 git-workflow-suite payloads
// ─────────────────────────────────────────────────────────────────────────────

/// Emitted after `sync_main` successfully fast-forwards the repo-root
/// main branch (or confirms it's already up-to-date).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeMainSyncedPayload {
    /// Main branch name (resolved if auto-detected).
    pub main_branch: String,
    /// HEAD before the sync.
    pub old_head: String,
    /// HEAD after the sync (equal to `old_head` when already up-to-date).
    pub new_head: String,
    /// Commits fast-forwarded. 0 means no-op.
    pub advanced_by: u64,
}

/// Emitted after `finalize_session` successfully merges + rebranches.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeSessionFinalizedPayload {
    /// Branch that was merged in.
    pub source_branch: String,
    /// Branch the merge landed on (usually `main`).
    pub target_branch: String,
    /// Merge commit sha (absent for FF — rare for finalize).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub merge_commit: Option<String>,
    /// Merge strategy used.
    pub strategy: String,
    /// Fresh follow-up branch the session moved onto after the merge.
    pub new_branch: String,
    /// New HEAD of the follow-up branch.
    pub new_base_commit: String,
    /// Whether the old source branch was deleted.
    pub old_branch_deleted: bool,
    /// If `preserve_old == false` but the delete failed, this holds the
    /// git error string. `None` otherwise.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_branch_delete_error: Option<String>,
}

/// Emitted when a merge-with-conflicts is started via
/// `start_merge_keep_conflicts`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeMergeStartedPayload {
    /// Source branch being merged.
    pub source_branch: String,
    /// Target branch receiving the merge.
    pub target_branch: String,
    /// Strategy being used.
    pub strategy: String,
    /// Count of conflicted files, if conflicts were detected at start.
    pub conflict_count: u32,
}

/// Emitted each time conflicts are detected or re-listed.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeConflictDetectedPayload {
    /// Source branch.
    pub source_branch: String,
    /// Target branch.
    pub target_branch: String,
    /// Origin discriminator: `"finalize"` (session→main), `"rebase_on_main"`
    /// (main→session), `"stash_pop"` (post-rebase stash carry-over conflict).
    pub origin: String,
    /// Conflicted file paths (repo-relative).
    pub paths: Vec<String>,
}

/// Emitted after one conflict is resolved.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeConflictResolvedPayload {
    /// File resolved.
    pub path: String,
    /// Resolution applied (`ours` / `theirs` / `manual`).
    pub resolution: String,
    /// Remaining conflicts in this merge.
    pub remaining: u32,
}

/// Emitted after `continue_merge` completes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeMergeContinuedPayload {
    /// Merge commit sha produced. For `StashPop` origin, this is the
    /// current HEAD (unchanged by the stash drop).
    pub merge_commit: String,
    /// Strategy used. `"stash_pop"` uses a dummy `"merge"`.
    pub strategy: String,
    /// Origin of the pending merge (`"finalize" | "rebase_on_main" | "stash_pop"`).
    pub origin: String,
}

/// Emitted after `abort_merge`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeMergeAbortedPayload {
    /// Strategy that was in flight.
    pub strategy: String,
    /// Reason for the abort. `"user"` / `"subagent_failed"` / `"auto_recovery"`
    /// / `"crash_recovery_timeout"`.
    pub reason: String,
    /// Origin of the aborted pending merge.
    pub origin: String,
}

/// Emitted after a push succeeds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreePushedPayload {
    /// Branch pushed.
    pub branch: String,
    /// Remote pushed to.
    pub remote: String,
    /// Whether `-u` was set on this push.
    pub set_upstream: bool,
    /// Whether this was a `--dry-run`.
    pub dry_run: bool,
    /// Whether `--force-with-lease` was used.
    pub force_with_lease: bool,
}

/// Emitted at coordinator startup when a pending merge is reconstructed
/// from `.git/MERGE_HEAD` / `.git/rebase-merge/` (crash recovery).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreePendingMergeDetectedPayload {
    /// Source branch (may be unknown — resolved from MERGE_MSG if possible).
    pub source_branch: String,
    /// Target branch.
    pub target_branch: String,
    /// Strategy in flight.
    pub strategy: String,
    /// Epoch ms when the merge started (derived from MERGE_MSG mtime).
    pub started_at_ms: u64,
    /// Epoch ms when the auto-abort timer fires.
    pub auto_abort_at_ms: u64,
}

/// Emitted after `rebase_on_main` advances a session branch to include
/// main's commits — either cleanly or after conflict resolution.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeRebasedOnMainPayload {
    /// Branch that was rebased onto (usually `main`).
    pub main_branch: String,
    /// Strategy used (`"rebase"` or `"merge"`).
    pub strategy: String,
    /// Session HEAD before the rebase.
    pub old_base_commit: String,
    /// Session HEAD after the rebase.
    pub new_base_commit: String,
    /// How many of main's commits landed on the session branch.
    pub main_commits_incorporated: u64,
    /// Whether the worktree was dirty at call time (triggering an
    /// auto-stash + pop).
    pub had_auto_stash: bool,
}

/// Emitted when `git stash pop` after a successful rebase produces
/// unmerged paths. The stash is left on the stack for manual recovery.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreePostRebaseStashConflictPayload {
    /// Ref of the stash left on the stash stack (e.g. `stash@{0}`).
    pub stash_ref: String,
    /// Paths reported as unmerged after the pop.
    pub paths: Vec<String>,
}

/// Emitted when orphaned dirty changes in a worktree were auto-committed
/// during recovery or branch deletion. The commit SHA is preserved so
/// iOS can surface a notice and the user can recover the work by name
/// (e.g. `git cherry-pick <sha>`).
///
/// There are two emission sites:
/// - Startup orphan sweep (`worktree::recovery::recover_repo`) — the
///   branch is kept when it has commits, so the SHA is reachable by
///   checking out the branch. `branch_removed = false`.
/// - User-initiated branch delete / prune
///   (`coordinator::branch::remove_worktree_if_present`) — both the
///   worktree and the branch are destroyed after the auto-commit, so
///   the SHA is only reachable via reflog. `branch_removed = true`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeAutoRecoveredCommitsPayload {
    /// Branch the commit was made on.
    pub branch: String,
    /// SHA of the auto-recovery commit.
    pub commit_hash: String,
    /// Worktree path at the time of recovery (may no longer exist).
    pub path: String,
    /// Whether the branch itself was removed after the commit. When
    /// `true` the commit is only reachable via reflog.
    pub branch_removed: bool,
}
