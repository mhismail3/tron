use std::path::PathBuf;

use crate::worktree::errors::Result;
use crate::worktree::types::{CommitEntry, CommittedDiffResult, CommittedFileEntry, DiffSummary};

use super::WorktreeCoordinator;
use super::utils::{count_diff_stats, split_diff_by_file};

impl WorktreeCoordinator {
    /// Get committed diff for a session's worktree branch.
    ///
    /// For active worktrees, uses the worktree path. For preserved branches,
    /// computes diff from repo root without checkout.
    pub async fn get_committed_diff(
        &self,
        session_id: &str,
    ) -> Result<Option<CommittedDiffResult>> {
        // First check active worktrees
        let active_info = { self.state.lock().active_info(session_id) };
        if let Some(info) = active_info {
            return self
                .committed_diff_for_branch(&info.repo_root, &info.branch, &info.base_commit)
                .await
                .map(Some);
        }

        // For preserved branches: find branch and base from WorktreeAcquired events
        let branch_prefix = format!("{}{session_id}", self.config.branch_prefix);

        // Try event store first — it has the original baseBranch and repoRoot
        let events = self
            .event_store
            .get_events_by_type(session_id, &["worktree.acquired"], Some(1))
            .unwrap_or_default();
        if let Some(event) = events.first()
            && let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
            && let (Some(branch), Some(base_branch)) = (
                payload.get("branch").and_then(|v| v.as_str()),
                payload.get("baseBranch").and_then(|v| v.as_str()),
            )
        {
            // Find the repo root from event payload or by scanning workspaces
            let repo_root = if let Some(root) = payload.get("repoRoot").and_then(|v| v.as_str()) {
                PathBuf::from(root)
            } else {
                // Fallback: scan workspaces
                match self.find_repo_for_branch(branch).await {
                    Some(root) => root,
                    None => return Ok(None),
                }
            };

            let base = self.git.merge_base(&repo_root, base_branch, branch).await?;
            return self
                .committed_diff_for_branch(&repo_root, branch, &base)
                .await
                .map(Some);
        }

        // Fallback: scan workspaces for matching branch (for sessions before baseBranch was persisted)
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            let pattern = format!("{branch_prefix}*");
            let branches = self
                .git
                .list_branches_matching(&repo_root, &pattern)
                .await
                .unwrap_or_default();
            if let Some(branch) = branches.first() {
                let base_branch = self.detect_default_branch(&repo_root).await;
                let base = self
                    .git
                    .merge_base(&repo_root, &base_branch, branch)
                    .await?;
                return self
                    .committed_diff_for_branch(&repo_root, branch, &base)
                    .await
                    .map(Some);
            }
        }

        Ok(None)
    }

    /// Internal: compute committed diff for a branch relative to a base commit.
    async fn committed_diff_for_branch(
        &self,
        repo_root: &std::path::Path,
        branch: &str,
        base_commit: &str,
    ) -> Result<CommittedDiffResult> {
        const MAX_DIFF_BYTES: usize = 1_024 * 1_024;

        let commit_count = self
            .git
            .commit_count_between(repo_root, base_commit, branch)
            .await
            .unwrap_or(0);

        let commits: Vec<CommitEntry> = if commit_count > 0 {
            self.git
                .branch_log(repo_root, branch, commit_count)
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|(hash, message, date)| CommitEntry {
                    hash,
                    message,
                    date,
                })
                .collect()
        } else {
            Vec::new()
        };

        if commits.is_empty() {
            return Ok(CommittedDiffResult {
                commits: Vec::new(),
                files: Vec::new(),
                summary: DiffSummary {
                    total_files: 0,
                    total_additions: 0,
                    total_deletions: 0,
                },
                truncated: false,
            });
        }

        let name_status = self
            .git
            .diff_name_status(repo_root, base_commit, branch)
            .await
            .unwrap_or_default();

        let raw_diff = self
            .git
            .diff_between(repo_root, base_commit, branch)
            .await
            .unwrap_or_default();

        let truncated = raw_diff.len() > MAX_DIFF_BYTES;
        let diff_str = if truncated {
            let safe_end = raw_diff.floor_char_boundary(MAX_DIFF_BYTES);
            &raw_diff[..safe_end]
        } else {
            &raw_diff
        };

        let diff_map = split_diff_by_file(diff_str);

        let mut files = Vec::new();
        let mut total_additions = 0usize;
        let mut total_deletions = 0usize;

        for (status, path) in &name_status {
            let (diff_text, additions, deletions) = if let Some(chunk) = diff_map.get(path) {
                if chunk.contains("Binary files") && chunk.contains("differ") {
                    (None, 0, 0)
                } else {
                    let (a, d) = count_diff_stats(chunk);
                    (Some(chunk.clone()), a, d)
                }
            } else {
                (None, 0, 0)
            };

            total_additions += additions;
            total_deletions += deletions;

            files.push(CommittedFileEntry {
                path: path.clone(),
                status: status.clone(),
                diff: diff_text,
                additions,
                deletions,
            });
        }

        Ok(CommittedDiffResult {
            commits,
            files: files.clone(),
            summary: DiffSummary {
                total_files: files.len(),
                total_additions,
                total_deletions,
            },
            truncated,
        })
    }

    /// Scan known workspaces to find which repo contains a given branch.
    async fn find_repo_for_branch(&self, branch: &str) -> Option<PathBuf> {
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            let branches = self
                .git
                .list_branches_matching(&repo_root, branch)
                .await
                .unwrap_or_default();
            if branches.iter().any(|b| b == branch) {
                return Some(repo_root);
            }
        }
        None
    }
}
