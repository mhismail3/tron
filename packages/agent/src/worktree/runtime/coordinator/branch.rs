use crate::worktree::errors::{Result, WorktreeError};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
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
