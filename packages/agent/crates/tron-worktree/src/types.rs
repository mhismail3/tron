//! Core types for worktree isolation.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

/// Re-export settings isolation mode for convenience.
pub use tron_settings::types::IsolationMode;

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
        }
    }
}

impl WorktreeConfig {
    /// Build from settings types.
    pub fn from_settings(
        session: &tron_settings::types::SessionSettings,
    ) -> Self {
        let iso = &session.isolation;
        Self {
            mode: iso.mode.clone(),
            base_dir_name: iso.base_dir.clone(),
            branch_prefix: iso.branch_prefix.clone(),
            auto_commit_on_release: iso.auto_commit_on_release,
            preserve_branches: iso.preserve_branches,
            delete_on_release: iso.delete_worktree_on_release,
            timeout_ms: session.worktree_timeout_ms,
        }
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

/// Result of attempting to acquire a worktree.
pub enum AcquireResult {
    /// Worktree created — use `worktree_path` as working directory.
    Acquired(WorktreeInfo),
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
        let mut session = tron_settings::types::SessionSettings::default();
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
