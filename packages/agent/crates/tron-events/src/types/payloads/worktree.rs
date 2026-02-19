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
