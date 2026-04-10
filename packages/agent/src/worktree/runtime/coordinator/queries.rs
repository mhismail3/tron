use tracing::warn;

use crate::worktree::errors::Result;
use crate::worktree::types::{SessionBranchInfo, WorktreeInfo};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// List all active worktrees.
    pub fn list_active(&self) -> Vec<WorktreeInfo> {
        self.state.lock().list_active()
    }

    /// List worktrees for a specific repo via `git worktree list`.
    pub async fn list_for_repo(
        &self,
        repo_root: &std::path::Path,
    ) -> Result<Vec<crate::worktree::git::WorktreeListEntry>> {
        self.git.worktree_list(repo_root).await
    }

    /// Get info for a specific session's worktree.
    pub fn get_info(&self, session_id: &str) -> Option<WorktreeInfo> {
        self.state.lock().active_info(session_id)
    }

    /// Get enriched status for a session's worktree.
    ///
    /// Queries git for uncommitted changes and commit count since base.
    pub async fn get_status(
        &self,
        session_id: &str,
    ) -> Result<Option<crate::worktree::types::WorktreeStatus>> {
        let Some(info) = self.state.lock().active_info(session_id) else {
            return Ok(None);
        };

        // Health check: verify worktree path and repo root still exist
        if !info.worktree_path.exists() || !self.git.is_git_repo(&info.repo_root).await {
            warn!(
                session_id,
                worktree_path = %info.worktree_path.display(),
                repo_root = %info.repo_root.display(),
                "worktree or repo root gone, releasing stale session"
            );
            self.state.lock().untrack(session_id);
            return Ok(None);
        }

        let has_changes = self
            .git
            .has_changes(&info.worktree_path)
            .await
            .unwrap_or(false);

        let commit_count = self
            .git
            .commit_count_since(&info.worktree_path, &info.base_commit)
            .await
            .unwrap_or(0);

        // Check if this branch has been merged into its base branch.
        let base_branch = info.base_branch.as_deref().unwrap_or("main");
        let is_merged = if commit_count > 0 {
            self.git
                .is_ancestor(&info.repo_root, &info.branch, base_branch)
                .await
        } else {
            false
        };

        Ok(Some(crate::worktree::types::WorktreeStatus {
            isolated: true,
            branch: info.branch,
            base_commit: info.base_commit,
            base_branch: info.base_branch,
            path: info.worktree_path.to_string_lossy().to_string(),
            repo_root: info.repo_root.to_string_lossy().to_string(),
            has_uncommitted_changes: has_changes,
            commit_count,
            is_merged,
        }))
    }

    /// List all session branches (active and preserved) for a repo.
    ///
    /// Scans for branches matching the configured prefix, cross-references
    /// with active worktrees for live state, and queries the event store
    /// for `baseBranch` on preserved branches.
    pub async fn list_session_branches(
        &self,
        repo_root: &std::path::Path,
    ) -> Result<Vec<SessionBranchInfo>> {
        let pattern = format!("{}*", self.config.branch_prefix);
        let branches = self.git.list_branches_matching(repo_root, &pattern).await?;

        // Build branch→base_branch map from events for preserved branches
        let event_base_branches = self.load_base_branches_from_events();
        let active_branches = self.state.lock().active_branch_snapshot();

        let mut results = Vec::with_capacity(branches.len());
        for branch in &branches {
            let log = match self.git.branch_log(repo_root, branch, 1).await {
                Ok(entries) if !entries.is_empty() => entries[0].clone(),
                _ => continue,
            };

            // Cross-reference with active map to get session_id, is_active, and base_branch
            let (is_active, session_id, base_branch) = if let Some((session_id, base_branch)) =
                active_branches.get(branch.as_str()).cloned()
            {
                (true, Some(session_id), base_branch)
            } else {
                let event_base = event_base_branches.get(branch.as_str()).cloned();
                let base = match event_base {
                    Some(b) => b,
                    None => self.detect_default_branch(repo_root).await,
                };
                (false, None, Some(base))
            };

            let commit_count = if let Some(ref base) = base_branch {
                let mb = self.git.merge_base(repo_root, base, branch).await.ok();
                if let Some(ref merge_base_sha) = mb {
                    self.git
                        .commit_count_between(repo_root, merge_base_sha, branch)
                        .await
                        .unwrap_or(0)
                } else {
                    0
                }
            } else {
                0
            };

            results.push(SessionBranchInfo {
                branch: branch.clone(),
                is_active,
                session_id,
                commit_count,
                last_commit_hash: log.0,
                last_commit_message: log.1,
                last_commit_date: log.2,
                base_branch,
            });
        }

        results.sort_by(|a, b| b.last_commit_date.cmp(&a.last_commit_date));
        Ok(results)
    }

    /// Build a `branch→base_branch` map by scanning `WorktreeAcquired` events.
    ///
    /// Also applies `worktree.renamed` events to re-key entries whose
    /// branch name changed after acquisition.
    fn load_base_branches_from_events(&self) -> std::collections::HashMap<String, String> {
        let mut map = std::collections::HashMap::new();
        let events = self
            .event_store
            .get_all_events_by_types(&["worktree.acquired"], Some(500), None)
            .unwrap_or_default();
        for event in &events {
            if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
                && let (Some(branch), Some(base)) = (
                    payload.get("branch").and_then(|v| v.as_str()),
                    payload.get("baseBranch").and_then(|v| v.as_str()),
                )
            {
                map.insert(branch.to_string(), base.to_string());
            }
        }

        // Apply renames: move entries from old branch key to new branch key
        let renames = self
            .event_store
            .get_all_events_by_types(&["worktree.renamed"], Some(500), None)
            .unwrap_or_default();
        for event in &renames {
            if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
                && let (Some(old), Some(new)) = (
                    payload.get("oldBranch").and_then(|v| v.as_str()),
                    payload.get("newBranch").and_then(|v| v.as_str()),
                )
            {
                if let Some(base) = map.remove(old) {
                    map.insert(new.to_string(), base);
                }
            }
        }

        map
    }
}
