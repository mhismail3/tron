//! Core types for worktree isolation.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Re-export settings isolation mode for convenience.
pub use crate::settings::types::IsolationMode;

/// Worktree isolation configuration (built from settings).
#[derive(Clone, Debug)]
pub struct WorktreeConfig {
    /// When to create worktrees.
    pub mode: IsolationMode,
    /// Directory name under repo root (e.g. `.worktrees`).
    pub base_dir_name: String,
    /// Branch name prefix (e.g. `session/`).
    pub branch_prefix: String,
    /// Auto-commit uncommitted changes on release.
    pub auto_commit_on_release: bool,
    /// Preserve the branch after deleting the worktree directory.
    pub preserve_branches: bool,
    /// Delete the worktree directory on release.
    pub delete_on_release: bool,
    /// Timeout for git commands in milliseconds.
    pub timeout_ms: u64,
    /// How long a crash-recovered pending merge can sit before being
    /// auto-aborted, in milliseconds. Default 30 minutes.
    pub auto_abort_ms: u64,
}

impl Default for WorktreeConfig {
    fn default() -> Self {
        Self {
            mode: IsolationMode::Always,
            base_dir_name: ".worktrees".to_string(),
            branch_prefix: "session/".to_string(),
            auto_commit_on_release: true,
            preserve_branches: true,
            delete_on_release: true,
            timeout_ms: 30_000,
            auto_abort_ms: 30 * 60 * 1000,
        }
    }
}

impl WorktreeConfig {
    /// Build from settings types.
    pub fn from_settings(session: &crate::settings::types::SessionSettings) -> Self {
        let iso = &session.isolation;
        Self {
            mode: iso.mode.clone(),
            base_dir_name: iso.base_dir.clone(),
            branch_prefix: iso.branch_prefix.clone(),
            auto_commit_on_release: iso.auto_commit_on_release,
            preserve_branches: iso.preserve_branches,
            delete_on_release: iso.delete_worktree_on_release,
            timeout_ms: session.worktree_timeout_ms,
            auto_abort_ms: 30 * 60 * 1000,
        }
    }

    /// Build from settings, threading in `git` workflow options.
    pub fn from_settings_with_git(
        session: &crate::settings::types::SessionSettings,
        git: &crate::settings::types::GitWorkflowSettings,
    ) -> Self {
        let mut cfg = Self::from_settings(session);
        cfg.auto_abort_ms = git.crash_recovery_abort_timeout_ms;
        cfg
    }
}

/// Information about an active worktree.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorktreeInfo {
    /// Session that owns this worktree.
    pub session_id: String,
    /// Absolute path to the worktree directory.
    pub worktree_path: PathBuf,
    /// Branch name (e.g. `session/abc123`).
    pub branch: String,
    /// Commit hash the worktree was based on.
    pub base_commit: String,
    /// Branch the worktree was created from (e.g. `main`).
    pub base_branch: Option<String>,
    /// Original working directory (the repo's main working tree).
    pub original_working_dir: PathBuf,
    /// Root of the git repository.
    pub repo_root: PathBuf,
}

/// Why worktree creation was deferred (repo exists but isn't ready).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeferralReason {
    /// Repository has no commits yet (`git init` without any commit).
    EmptyRepository,
}

/// Result of attempting to acquire a worktree.
#[derive(Debug)]
pub enum AcquireResult {
    /// Worktree created — use `worktree_path` as working directory.
    Acquired(WorktreeInfo),
    /// Worktree creation deferred — repo exists but isn't ready yet.
    /// Will be re-evaluated on the next turn.
    Deferred(DeferralReason),
    /// No worktree needed — use original working directory.
    Passthrough,
}

/// Merge strategy for integrating session work back into a target branch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MergeStrategy {
    /// Standard merge commit (--no-ff).
    Merge,
    /// Rebase onto target then fast-forward.
    Rebase,
    /// Squash all commits into one on target.
    Squash,
}

impl MergeStrategy {
    /// Canonical wire label (`"merge" | "rebase" | "squash"`).
    ///
    /// Used by RPC handlers and event payload builders — lives here so
    /// every call site agrees on the casing.
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Merge => "merge",
            Self::Rebase => "rebase",
            Self::Squash => "squash",
        }
    }
}

/// Result of a merge operation.
#[derive(Clone, Debug)]
pub struct MergeResult {
    /// Whether the merge succeeded.
    pub success: bool,
    /// Merge commit hash (if applicable).
    pub merge_commit: Option<String>,
    /// Conflicting files (empty if no conflicts).
    pub conflicts: Vec<String>,
    /// Strategy that was used.
    pub strategy: MergeStrategy,
}

/// Enriched worktree status for RPC responses.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorktreeStatus {
    /// Whether isolation is active.
    pub isolated: bool,
    /// Branch name.
    pub branch: String,
    /// Commit hash the worktree was based on.
    pub base_commit: String,
    /// Base branch (e.g. "main").
    pub base_branch: Option<String>,
    /// Absolute path to the worktree directory.
    pub path: String,
    /// Root of the git repository.
    pub repo_root: String,
    /// Whether there are uncommitted changes in the worktree.
    pub has_uncommitted_changes: bool,
    /// Number of commits made since the worktree was created.
    pub commit_count: usize,
    /// Whether all commits on this branch have been merged into the base branch.
    pub is_merged: bool,
}

/// Result of a commit operation in a worktree.
#[derive(Clone, Debug)]
pub struct CommitResult {
    /// Commit hash.
    pub commit_hash: String,
    /// Files changed in this commit.
    pub files_changed: Vec<String>,
    /// Lines inserted.
    pub insertions: usize,
    /// Lines deleted.
    pub deletions: usize,
}

/// Options that modify how a commit is constructed.
///
/// `stage_all` defaults to `true` to preserve the existing "stage everything
/// then commit" behavior that lifecycle/recovery paths rely on. Explicit user
/// flows (the iOS Commit sheet) may opt out.
#[derive(Clone, Debug, Default)]
pub struct CommitOptions {
    /// `--amend`: rewrite the previous HEAD commit rather than adding a new one.
    pub amend: bool,
    /// `--signoff`: append a `Signed-off-by` trailer to the commit message.
    pub signoff: bool,
    /// If `true`, run `git add -A` before committing so every tracked and
    /// untracked file is staged. If `false`, commit only the current index.
    pub stage_all: bool,
}

impl CommitOptions {
    /// Default behavior prior to the options parameter: stage all, no amend,
    /// no signoff. Used by internal callers (lifecycle, recovery) to preserve
    /// existing semantics when the new `commit_with_options` path is wired in.
    pub fn default_stage_all() -> Self {
        Self {
            stage_all: true,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod commit_options_tests {
    use super::CommitOptions;

    #[test]
    fn commit_options_default_stages_all() {
        let opts = CommitOptions::default_stage_all();
        assert!(opts.stage_all, "default_stage_all must set stage_all=true");
        assert!(!opts.amend, "default_stage_all must not amend");
        assert!(!opts.signoff, "default_stage_all must not signoff");
    }

    #[test]
    fn commit_options_derived_default_is_noop() {
        let opts = CommitOptions::default();
        assert!(!opts.stage_all);
        assert!(!opts.amend);
        assert!(!opts.signoff);
    }
}

/// Information returned when a worktree is released.
#[derive(Clone, Debug)]
pub struct ReleaseInfo {
    /// Final commit hash (if an auto-commit was made).
    pub final_commit: Option<String>,
    /// Whether the worktree directory was deleted.
    pub deleted: bool,
    /// Whether the branch was preserved.
    pub branch_preserved: bool,
}

/// Information about a session branch (active or preserved).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionBranchInfo {
    /// Full branch name (e.g. `session/abc123`).
    pub branch: String,
    /// Whether this branch has an active worktree.
    pub is_active: bool,
    /// Session ID that owns/owned this branch.
    pub session_id: Option<String>,
    /// Number of commits ahead of base.
    pub commit_count: usize,
    /// Last commit hash.
    pub last_commit_hash: String,
    /// Last commit message.
    pub last_commit_message: String,
    /// Last commit date (ISO 8601).
    pub last_commit_date: String,
    /// Branch this was based on (e.g. `main`).
    pub base_branch: Option<String>,
}

/// Result of fetching committed changes for a session.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommittedDiffResult {
    /// Commits in this branch since the base.
    pub commits: Vec<CommitEntry>,
    /// Per-file change information.
    pub files: Vec<CommittedFileEntry>,
    /// Aggregate summary.
    pub summary: DiffSummary,
    /// Whether the diff was truncated due to size.
    pub truncated: bool,
}

/// A single commit entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitEntry {
    /// Full commit hash.
    pub hash: String,
    /// Commit message.
    pub message: String,
    /// Commit date (ISO 8601).
    pub date: String,
}

/// Per-file entry in a committed diff.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommittedFileEntry {
    /// File path.
    pub path: String,
    /// Change status (A, M, D, R, etc.).
    pub status: String,
    /// Unified diff text (None for binary or too-large files).
    pub diff: Option<String>,
    /// Lines added.
    pub additions: usize,
    /// Lines deleted.
    pub deletions: usize,
}

/// Aggregate diff summary.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffSummary {
    /// Total files changed.
    pub total_files: usize,
    /// Total lines added.
    pub total_additions: usize,
    /// Total lines deleted.
    pub total_deletions: usize,
}

/// Result of deleting a single session branch.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeleteBranchResult {
    /// Branch name that was deleted.
    pub branch: String,
    /// Whether the branch had unmerged commits.
    pub had_unmerged_commits: bool,
    /// Number of unmerged commits.
    pub unmerged_count: usize,
}

/// Result of pruning all inactive session branches.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PruneBranchesResult {
    /// Branches that were successfully deleted.
    pub deleted: Vec<String>,
    /// Branches that failed to delete.
    pub failed: Vec<PruneFailure>,
}

/// A branch that failed to be pruned.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PruneFailure {
    /// Branch name.
    pub branch: String,
    /// Error message.
    pub error: String,
}

// ────────────────────────────────────────────────────────────────────────
// Phase 1 — git primitive output types
// ────────────────────────────────────────────────────────────────────────

/// Structured output from a `git push`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PushOutput {
    /// Whether the push succeeded at the ref level. A dry-run that would
    /// have succeeded still returns `true`.
    pub success: bool,
    /// The branch that was pushed.
    pub branch: String,
    /// The remote that was pushed to (e.g. `origin`).
    pub remote: String,
    /// Whether `--set-upstream` was used to establish tracking.
    pub set_upstream: bool,
    /// Whether this was a dry run (no side effects).
    pub dry_run: bool,
    /// Raw stderr (git prints `To <url>` / `+ <ref>` info to stderr).
    pub stderr: String,
}

/// A file with unresolved merge/rebase conflicts, including the three
/// stages pulled from the index.
///
/// Stage numbering matches git:
/// - `base`  — stage 1 (common ancestor; `None` if this was an add/add or
///   rename/rename conflict where there is no common ancestor content).
/// - `ours`  — stage 2 (the currently-checked-out side).
/// - `theirs` — stage 3 (the side being merged in).
///
/// Each side is `Option<Vec<u8>>` because:
/// - `None` ≈ "not present on this side" (delete/modify conflicts).
/// - `Some(bytes)` ≈ raw blob contents (may be binary).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConflictedFile {
    /// Path relative to the repo root.
    pub path: String,
    /// Whether git detected the blob(s) as binary.
    pub is_binary: bool,
    /// Content of the common ancestor (stage 1).
    pub base: Option<Vec<u8>>,
    /// Content as we had it (stage 2).
    pub ours: Option<Vec<u8>>,
    /// Content as the incoming side had it (stage 3).
    pub theirs: Option<Vec<u8>>,
    /// Broad category reported by git's `ls-files --unmerged` / `status`.
    pub kind: ConflictKind,
}

/// What kind of conflict a file represents.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConflictKind {
    /// Both sides modified the file (classic content conflict).
    BothModified,
    /// Both sides added the file with different content.
    BothAdded,
    /// Our side deleted, theirs modified.
    DeletedByUs,
    /// Theirs deleted, we modified.
    DeletedByThem,
    /// Both sides renamed the file to different names, or a rename collided
    /// with a modification. Reported generically — callers that care about
    /// the exact shape should inspect `git status` directly.
    Rename,
    /// Something else (mode conflict, submodule conflict, etc.).
    Other,
}

// ────────────────────────────────────────────────────────────────────────
// Phase 2 — SCM module result types
// ────────────────────────────────────────────────────────────────────────

/// Outcome of `sync_main` (fast-forward local `main` from its upstream).
///
/// The variants mirror the three shapes the caller must distinguish:
/// 1. Already up-to-date → no-op.
/// 2. Fast-forwarded → local advanced by N commits.
/// 3. Blocked → could not proceed safely; caller gets a typed reason so
///    the iOS UI can show appropriate guidance ("pull with rebase",
///    "commit or stash first", "configure origin", etc.).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncOutcome {
    /// Local was already at or past the remote.
    UpToDate {
        /// Commit HEAD points at.
        head: String,
    },
    /// Local was fast-forwarded `advanced_by` commits to `new_head`.
    FastForwarded {
        /// Commit HEAD previously pointed at.
        old_head: String,
        /// New HEAD after FF.
        new_head: String,
        /// How many commits were pulled in.
        advanced_by: usize,
    },
    /// Dry-run result: shows what a real sync would do without modifying
    /// local `main`. The fetch still ran (so remote-tracking refs are fresh
    /// and `--prune` is honored), but no fast-forward was applied.
    DryRunPreview {
        /// Current local HEAD (unchanged).
        head: String,
        /// Remote tip that a real sync would fast-forward to.
        remote_head: String,
        /// How many commits the FF would advance.
        would_advance_by: usize,
    },
    /// Sync did not run; caller must address the blocker first.
    Blocked(SyncBlockReason),
}

/// Why a sync did not run. Surfaces as typed variants (mapped into the
/// iOS `PullRemoteSubSheet` banner without string-matching).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncBlockReason {
    /// No remote configured for the repo.
    NoRemote,
    /// Working tree at repo root has uncommitted changes.
    DirtyWorkingTree,
    /// Local has commits the remote doesn't — must push first.
    LocalAhead {
        /// How many commits local is ahead.
        ahead: usize,
    },
    /// Local and remote have diverged — caller chooses rebase vs merge.
    Diverged {
        /// Commits local is ahead.
        ahead: usize,
        /// Commits local is behind.
        behind: usize,
    },
    /// Repo has no commits yet.
    EmptyRepository,
    /// HEAD is detached; we can't safely fast-forward.
    DetachedHead,
    /// Default branch (`main`/`master`) could not be resolved.
    NoDefaultBranch,
    /// HEAD is on a branch other than the default. Sync operates in-place
    /// on the repo-root checkout; silently switching branches would be a
    /// footgun so we refuse.
    NotOnDefaultBranch {
        /// Name of the branch HEAD is currently on.
        current: String,
        /// Default branch that sync wants to advance.
        expected: String,
    },
    /// Remote operation failed (timeout, auth, etc.). Message is human-
    /// readable and safe to show the user.
    RemoteError(String),
}

/// Result of `finalize_session` — the "merge session branch into main and
/// move session to a fresh follow-up branch" atomic operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FinalizeSessionResult {
    /// The merge commit written onto the target branch.
    pub merge_commit: String,
    /// The freshly-created follow-up branch the worktree now points at.
    pub new_branch: String,
    /// HEAD of the new follow-up branch (same as the target branch tip).
    pub new_base_commit: String,
    /// Whether the old session branch was deleted (`!preserve_old`).
    pub old_branch_deleted: bool,
    /// If the delete was requested (`!preserve_old`) but failed, this
    /// carries the git error message so the UI can surface it. `None`
    /// when preserve_old was true OR when the delete succeeded.
    pub old_branch_delete_error: Option<String>,
    /// Merge strategy that was actually used.
    pub strategy: MergeStrategy,
}

/// Origin of a pending merge — tells `continue_merge` / `abort_merge`
/// which post-op lifecycle to run (`rebase_on_main` carries over an
/// auto-stash; `finalize` does not; `stash_pop` drops a stash on continue
/// and preserves it on abort).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeOrigin {
    /// Started by `worktree.startMerge` (part of the session-into-main
    /// finalize workflow).
    Finalize,
    /// Started by `worktree.rebaseOnMain` (pulls main forward into the
    /// session branch). Carries `auto_stash_ref` when the worktree was
    /// dirty at call time.
    RebaseOnMain,
    /// Synthesised when `git stash pop` (post-rebase stash carry-over)
    /// produces unmerged paths. There is no `.git/MERGE_HEAD` /
    /// `.git/rebase-merge` on disk; conflicts live purely in the index as
    /// unmerged entries. `continue_merge` drops the stash; `abort_merge`
    /// does `git reset --hard HEAD` and preserves the stash on the stack.
    StashPop,
}

impl MergeOrigin {
    /// Canonical wire label (`"finalize" | "rebase_on_main" | "stash_pop"`).
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Finalize => "finalize",
            Self::RebaseOnMain => "rebase_on_main",
            Self::StashPop => "stash_pop",
        }
    }
}

/// In-flight merge/rebase state kept by the coordinator for the duration
/// of a conflict resolution session.
///
/// Reconstructed from `.git/MERGE_HEAD` (or `.git/rebase-merge/`) on
/// coordinator startup so a crash mid-merge doesn't silently lose state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingMergeState {
    /// The session this merge belongs to.
    pub session_id: String,
    /// Which branch we were merging from.
    pub source_branch: String,
    /// Which branch we were merging into.
    pub target_branch: String,
    /// Strategy that was used (Merge / Rebase / Squash).
    pub strategy: MergeStrategy,
    /// Unix millis when the merge started. Used for the
    /// `crash_recovery_abort_timeout_ms` auto-abort.
    pub started_at_ms: i64,
    /// Did we recover this from disk at coordinator startup (vs start it
    /// this process)?
    pub crash_recovered: bool,
    /// Where this pending merge came from — drives whether
    /// `continue_merge` pops a stash and emits `worktree.rebased_on_main`.
    pub origin: MergeOrigin,
    /// Ref of a `git stash store`d entry created by `rebase_on_main`
    /// when the worktree was dirty at call time. `Some` iff the worktree
    /// had uncommitted changes at the time of rebase.
    pub auto_stash_ref: Option<String>,
}

/// Result of `rebase_on_main` — the "pull main forward into the session
/// branch" operation. Variants mirror the three shapes the caller must
/// distinguish on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RebaseOnMainResult {
    /// Session branch moved forward to include main's commits (either
    /// cleanly via fast-forward / rebase, or after conflict resolution
    /// in a separate RPC).
    Success {
        /// Session HEAD before the rebase.
        old_base_commit: String,
        /// Session HEAD after the rebase.
        new_base_commit: String,
        /// How many of main's commits were incorporated.
        main_commits_incorporated: usize,
        /// Strategy used (Rebase or Merge).
        strategy: MergeStrategy,
        /// Whether the worktree was dirty and got auto-stashed + popped.
        had_auto_stash: bool,
    },
    /// Rebase produced conflicts that the user must resolve via the
    /// existing conflict state machine (`worktree.listConflicts` +
    /// `worktree.resolveConflict` + `worktree.continueMerge`).
    Conflicts {
        /// Number of conflicted files at the point of detection.
        count: usize,
    },
    /// Session was already up to date with main — no lock taken, no
    /// events emitted, no stash created.
    NoOp {
        /// Commits the session is ahead of main (informational).
        ahead: usize,
    },
}

/// Instruction for `resolve_conflict`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ConflictResolution {
    /// Take our side's content (stage 2).
    Ours,
    /// Take their side's content (stage 3).
    Theirs,
    /// The file has already been edited and is ready — just mark resolved
    /// (`git add <path>`).
    MarkResolved,
}

impl ConflictResolution {
    /// Canonical wire label (`"ours" | "theirs" | "markResolved"`).
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Ours => "ours",
            Self::Theirs => "theirs",
            Self::MarkResolved => "markResolved",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_defaults() {
        let c = WorktreeConfig::default();
        assert_eq!(c.mode, IsolationMode::Always);
        assert_eq!(c.base_dir_name, ".worktrees");
        assert_eq!(c.branch_prefix, "session/");
        assert!(c.auto_commit_on_release);
        assert!(c.preserve_branches);
        assert!(c.delete_on_release);
        assert_eq!(c.timeout_ms, 30_000);
    }

    #[test]
    fn config_from_settings() {
        let mut session = crate::settings::types::SessionSettings::default();
        session.isolation.mode = IsolationMode::Never;
        session.isolation.branch_prefix = "wt/".to_string();
        session.worktree_timeout_ms = 60_000;

        let c = WorktreeConfig::from_settings(&session);
        assert_eq!(c.mode, IsolationMode::Never);
        assert_eq!(c.branch_prefix, "wt/");
        assert_eq!(c.timeout_ms, 60_000);
    }

    #[test]
    fn merge_strategy_serde() {
        for (strategy, expected) in [
            (MergeStrategy::Merge, "\"merge\""),
            (MergeStrategy::Rebase, "\"rebase\""),
            (MergeStrategy::Squash, "\"squash\""),
        ] {
            let json = serde_json::to_string(&strategy).unwrap();
            assert_eq!(json, expected);
            let back: MergeStrategy = serde_json::from_str(&json).unwrap();
            assert_eq!(back, strategy);
        }
    }

    #[test]
    fn worktree_info_serde_roundtrip() {
        let info = WorktreeInfo {
            session_id: "sess-123".to_string(),
            worktree_path: PathBuf::from("/repo/.worktrees/session/abc"),
            branch: "session/abc".to_string(),
            base_commit: "deadbeef".to_string(),
            base_branch: Some("main".to_string()),
            original_working_dir: PathBuf::from("/repo"),
            repo_root: PathBuf::from("/repo"),
        };
        let json = serde_json::to_string(&info).unwrap();
        let back: WorktreeInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(back.session_id, "sess-123");
        assert_eq!(back.branch, "session/abc");
    }
}
