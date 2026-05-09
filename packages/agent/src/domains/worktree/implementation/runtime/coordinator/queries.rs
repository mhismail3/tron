use tracing::warn;

use crate::domains::worktree::errors::Result;
use crate::domains::worktree::types::{SessionBranchInfo, WorktreeInfo};

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
    ) -> Result<Vec<crate::domains::worktree::git::WorktreeListEntry>> {
        self.git.worktree_list(repo_root).await
    }

    /// Get info for a specific session's worktree.
    pub fn get_info(&self, session_id: &str) -> Option<WorktreeInfo> {
        self.state.lock().active_info(session_id)
    }

    /// List every local branch in the session's repo. Session/* branches
    /// are returned last; mainline-sounding branches (main, master,
    /// develop) are floated to the top so the picker UI can default
    /// correctly.
    pub async fn list_local_branches(
        &self,
        session_id: &str,
        fallback_dir: Option<&std::path::Path>,
    ) -> Result<Vec<String>> {
        let repo_root = self.repo_root_or_cwd(session_id, fallback_dir).await?;
        let mut branches = self.git.list_branches_matching(&repo_root, "*").await?;
        let rank = |b: &str| -> u8 {
            if b == "main" || b == "master" {
                0
            } else if b == "develop" || b == "dev" {
                1
            } else if b.starts_with(&self.config.branch_prefix) {
                3
            } else {
                2
            }
        };
        branches.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
        Ok(branches)
    }

    /// List published branch names on the given remote (default `origin`).
    /// Returns names with the remote prefix stripped. Used by the Merge
    /// Changes target picker so merge targets are restricted to shared/
    /// published branches — session branches and unpushed local branches are
    /// never valid merge targets in this UI.
    ///
    /// Mainline-sounding branches (`main`, `master`, `develop`, `dev`) are
    /// floated to the top the same way as `list_local_branches` so the
    /// picker's default is consistent.
    pub async fn list_remote_branches(
        &self,
        session_id: &str,
        remote: Option<&str>,
        fallback_dir: Option<&std::path::Path>,
    ) -> Result<Vec<String>> {
        let repo_root = self.repo_root_or_cwd(session_id, fallback_dir).await?;
        let remote_name = remote.unwrap_or("origin");
        let mut branches = self
            .git
            .list_remote_branches(&repo_root, remote_name)
            .await?;
        let rank = |b: &str| -> u8 {
            if b == "main" || b == "master" {
                0
            } else if b == "develop" || b == "dev" {
                1
            } else {
                2
            }
        };
        branches.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
        Ok(branches)
    }

    /// Count commits on `head` that are not on `base` (i.e. how far ahead
    /// `head` is). Delegates to `git.commit_count_between`.
    pub async fn commit_count(
        &self,
        repo_root: &std::path::Path,
        base: &str,
        head: &str,
    ) -> Result<usize> {
        let mb = self.git.merge_base(repo_root, base, head).await?;
        self.git.commit_count_between(repo_root, &mb, head).await
    }

    /// Compute `(ahead, behind)` for two refs sharing a merge base.
    /// Both values are 0 when the refs are equal or the merge base
    /// equals both.
    pub async fn ahead_behind(
        &self,
        repo_root: &std::path::Path,
        base: &str,
        head: &str,
    ) -> Result<(usize, usize)> {
        let mb = self.git.merge_base(repo_root, base, head).await?;
        let ahead = self
            .git
            .commit_count_between(repo_root, &mb, head)
            .await
            .unwrap_or(0);
        let behind = self
            .git
            .commit_count_between(repo_root, &mb, base)
            .await
            .unwrap_or(0);
        Ok((ahead, behind))
    }

    /// Like [`ahead_behind`] but returns `Ok(None)` when either ref fails
    /// to resolve (e.g. no origin remote configured, no upstream set, stale
    /// ref). Callers use this to distinguish "genuinely 0/0" from
    /// "comparison not applicable" so the UI can fade or hide the chip
    /// instead of lying with a zero.
    pub async fn ahead_behind_optional(
        &self,
        repo_root: &std::path::Path,
        base: &str,
        head: &str,
    ) -> Result<Option<(usize, usize)>> {
        match self.git.merge_base(repo_root, base, head).await {
            Ok(mb) => {
                let ahead = self
                    .git
                    .commit_count_between(repo_root, &mb, head)
                    .await
                    .unwrap_or(0);
                let behind = self
                    .git
                    .commit_count_between(repo_root, &mb, base)
                    .await
                    .unwrap_or(0);
                Ok(Some((ahead, behind)))
            }
            Err(_) => Ok(None),
        }
    }

    /// Returns `true` when `remote` is configured on `repo_root`.
    pub async fn has_remote(&self, repo_root: &std::path::Path, remote: &str) -> bool {
        self.git
            .remote_list(repo_root)
            .await
            .map(|v| v.iter().any(|r| r == remote))
            .unwrap_or(false)
    }

    /// Get enriched status for a session's worktree.
    ///
    /// Queries git for uncommitted changes and commit count since base.
    pub async fn get_status(
        &self,
        session_id: &str,
    ) -> Result<Option<crate::domains::worktree::types::WorktreeStatus>> {
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

        Ok(Some(crate::domains::worktree::types::WorktreeStatus {
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

    /// Build a passthrough `WorktreeStatus` for a session that never
    /// acquired an isolated worktree (the session is running directly
    /// against the repo root — e.g. a fresh session on `main`, or a
    /// post-finalize session whose worktree was released).
    ///
    /// Returns `Ok(None)` when `working_dir` is not inside a git repo.
    pub async fn passthrough_status(
        &self,
        working_dir: &std::path::Path,
    ) -> Result<Option<crate::domains::worktree::types::WorktreeStatus>> {
        if !self.git.is_git_repo(working_dir).await {
            return Ok(None);
        }
        let repo_root_str = match self.git.repo_root(working_dir).await {
            Ok(r) => r,
            Err(_) => return Ok(None),
        };
        let repo_root = std::path::Path::new(&repo_root_str);
        // On detached HEAD `current_branch` errors — surface the short
        // commit hash instead so the UI shows something meaningful.
        let branch = match self.git.current_branch(repo_root).await {
            Ok(b) => b,
            Err(_) => self
                .git
                .head_commit(repo_root)
                .await
                .map(|h| h.chars().take(7).collect())
                .unwrap_or_else(|_| "HEAD".to_string()),
        };
        let head = self.git.head_commit(repo_root).await.unwrap_or_default();
        let has_changes = self.git.has_changes(repo_root).await.unwrap_or(false);
        Ok(Some(crate::domains::worktree::types::WorktreeStatus {
            isolated: false,
            branch,
            base_commit: head,
            base_branch: None,
            path: repo_root_str.clone(),
            repo_root: repo_root_str,
            has_uncommitted_changes: has_changes,
            commit_count: 0,
            is_merged: false,
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
