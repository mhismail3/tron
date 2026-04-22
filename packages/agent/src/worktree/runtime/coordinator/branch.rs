use std::path::PathBuf;

use serde_json::json;
use tracing::{info, warn};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::errors::{Result, WorktreeError};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Remove a linked worktree for a branch, if one exists.
    ///
    /// Handles orphaned worktrees that were never properly released (e.g. after
    /// a database wipe). Auto-commits any dirty changes before removal to
    /// prevent data loss. Errors are logged but do not propagate — the caller
    /// should proceed with `branch_delete` regardless, which will fail with a
    /// clear git error if the worktree could not be removed.
    async fn remove_worktree_if_present(&self, repo_root: &std::path::Path, branch: &str) {
        let entries = match self.git.worktree_list(repo_root).await {
            Ok(e) => e,
            Err(e) => {
                warn!(branch, error = %e, "failed to list worktrees");
                return;
            }
        };

        let entry = match entries.iter().find(|e| e.branch.as_deref() == Some(branch)) {
            Some(e) => e,
            None => return,
        };

        let wt_path = PathBuf::from(&entry.path);

        if wt_path.exists() {
            // Auto-commit dirty changes to prevent data loss
            if let Ok(true) = self.git.has_changes(&wt_path).await {
                match self
                    .git
                    .commit_all(&wt_path, "[auto-recovered] orphaned session changes")
                    .await
                {
                    Ok(sha) => {
                        info!(branch, commit = %sha, "auto-committed orphan changes");
                        self.emit_auto_recovered(branch, &sha, &wt_path, true);
                    }
                    Err(e) => warn!(branch, error = %e, "failed to auto-commit orphan"),
                }
            }

            // Remove the worktree
            if let Err(e) = self.git.worktree_remove(repo_root, &wt_path, true).await {
                warn!(branch, error = %e, "failed to remove orphan worktree, trying manual cleanup");
                let _ = tokio::fs::remove_dir_all(&wt_path).await;
            }
        }

        // Clean stale refs regardless
        let _ = self.git.worktree_prune(repo_root).await;
    }

    /// Record a `worktree.auto_recovered_commits` event for a branch
    /// whose dirty changes were auto-committed before destruction.
    /// No-ops when the branch doesn't carry a resolvable session id or
    /// when no session row exists for it — the event is an iOS notice,
    /// and there's no timeline to attach to when the session is gone.
    fn emit_auto_recovered(
        &self,
        branch: &str,
        sha: &str,
        wt_path: &std::path::Path,
        branch_removed: bool,
    ) {
        let Some(session_id) = branch.strip_prefix(&self.config.branch_prefix) else {
            return;
        };
        if session_id.is_empty() {
            return;
        }
        if self
            .event_store
            .get_session(session_id)
            .ok()
            .flatten()
            .is_none()
        {
            return;
        }
        let path_str = wt_path.to_string_lossy().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeAutoRecoveredCommits,
            payload: json!({
                "branch": branch,
                "commitHash": sha,
                "path": path_str,
                "branchRemoved": branch_removed,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeAutoRecoveredCommits {
            base: BaseEvent::now(session_id),
            branch: branch.to_string(),
            commit_hash: sha.to_string(),
            path: path_str,
            branch_removed,
        });
    }

    /// Delete a single session branch by name.
    ///
    /// Refuses to delete branches with active worktrees. Returns info about
    /// whether unmerged commits were lost.
    pub async fn delete_session_branch(
        &self,
        repo_root: &std::path::Path,
        branch: &str,
    ) -> Result<crate::worktree::types::DeleteBranchResult> {
        use crate::worktree::types::DeleteBranchResult;

        if !branch.starts_with(&self.config.branch_prefix) {
            return Err(WorktreeError::Git(format!(
                "branch '{branch}' does not match prefix '{}'",
                self.config.branch_prefix
            )));
        }

        // Reject if the branch is active
        let active = self.state.lock().active_branch_snapshot();
        if active.contains_key(branch) {
            return Err(WorktreeError::BranchActive(branch.to_string()));
        }

        // Count unmerged commits
        let default_branch = self.detect_default_branch(repo_root).await;
        let unmerged_count = if let Ok(mb) = self.git.merge_base(repo_root, &default_branch, branch).await {
            self.git
                .commit_count_between(repo_root, &mb, branch)
                .await
                .unwrap_or(0)
        } else {
            0
        };

        self.remove_worktree_if_present(repo_root, branch).await;
        self.git.branch_delete(repo_root, branch, true).await?;

        Ok(DeleteBranchResult {
            branch: branch.to_string(),
            had_unmerged_commits: unmerged_count > 0,
            unmerged_count,
        })
    }

    /// Prune all inactive session branches.
    pub async fn prune_session_branches(
        &self,
        repo_root: &std::path::Path,
    ) -> Result<crate::worktree::types::PruneBranchesResult> {
        use crate::worktree::types::{PruneBranchesResult, PruneFailure};

        let all = self.list_session_branches(repo_root).await?;
        let mut deleted = Vec::new();
        let mut failed = Vec::new();

        for info in &all {
            if info.is_active {
                continue;
            }

            self.remove_worktree_if_present(repo_root, &info.branch).await;

            match self.git.branch_delete(repo_root, &info.branch, true).await {
                Ok(()) => deleted.push(info.branch.clone()),
                Err(e) => failed.push(PruneFailure {
                    branch: info.branch.clone(),
                    error: e.to_string(),
                }),
            }
        }

        Ok(PruneBranchesResult { deleted, failed })
    }

    /// Detect the default branch for a repo (tries main, then master, then current).
    pub(super) async fn detect_default_branch(&self, repo_root: &std::path::Path) -> String {
        let branches = self
            .git
            .list_branches_matching(repo_root, "*")
            .await
            .unwrap_or_default();
        for candidate in &["main", "master"] {
            if branches.iter().any(|b| b == candidate) {
                return candidate.to_string();
            }
        }
        self.git
            .current_branch(repo_root)
            .await
            .unwrap_or_else(|_| "main".to_string())
    }
}
