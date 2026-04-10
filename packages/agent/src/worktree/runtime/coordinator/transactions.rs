use serde_json::json;
use tracing::debug;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};

use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::types::{MergeResult, MergeStrategy};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Commit changes in a session's worktree.
    ///
    /// Emits `worktree.commit` event with file list and diff stats.
    /// Returns `None` if there are no changes to commit.
    pub async fn commit(
        &self,
        session_id: &str,
        message: &str,
    ) -> Result<Option<crate::worktree::types::CommitResult>> {
        let info = self
            .state
            .lock()
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        if !self.git.has_changes(&info.worktree_path).await? {
            return Ok(None);
        }

        // Capture pre-commit HEAD to compute diff stats after commit
        let pre_commit = self
            .git
            .head_commit(&info.worktree_path)
            .await
            .unwrap_or_default();

        let sha = self.git.commit_all(&info.worktree_path, message).await?;

        // Gather files changed and diff stats between pre-commit and new HEAD
        let files_changed = if pre_commit.is_empty() {
            Vec::new()
        } else {
            self.git
                .changed_files_since(&info.worktree_path, &pre_commit)
                .await
                .unwrap_or_default()
        };

        let (insertions, deletions) = if pre_commit.is_empty() {
            (0, 0)
        } else {
            self.git
                .diff_numstat_total(&info.worktree_path, &pre_commit, &sha)
                .await
                .unwrap_or((0, 0))
        };

        // Query server-authoritative post-commit state
        #[allow(clippy::cast_possible_truncation)]
        let total_commit_count = self
            .git
            .commit_count_since(&info.worktree_path, &info.base_commit)
            .await
            .unwrap_or(0) as u64;
        let has_uncommitted_changes = self
            .git
            .has_changes(&info.worktree_path)
            .await
            .unwrap_or(false);

        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeCommit,
            payload: json!({
                "commitHash": sha,
                "message": message,
                "filesChanged": files_changed,
                "insertions": insertions,
                "deletions": deletions,
                "totalCommitCount": total_commit_count,
                "hasUncommittedChanges": has_uncommitted_changes,
            }),
            parent_id: None,
            sequence: None,
        });

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeCommit {
            base: BaseEvent::now(session_id),
            commit_hash: sha.clone(),
            message: message.to_string(),
            files_changed: files_changed.clone(),
            insertions,
            deletions,
            total_commit_count,
            has_uncommitted_changes,
        });

        debug!(session_id, commit = %sha, files = files_changed.len(), "committed in worktree");
        Ok(Some(crate::worktree::types::CommitResult {
            commit_hash: sha,
            files_changed,
            insertions,
            deletions,
        }))
    }

    /// Merge a session's branch into a target branch.
    ///
    /// Emits `worktree.merged` event on success.
    pub async fn merge(
        &self,
        session_id: &str,
        target_branch: &str,
        strategy: MergeStrategy,
    ) -> Result<MergeResult> {
        let info = self
            .state
            .lock()
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        let result = crate::worktree::merge::merge_session(
            &info.repo_root,
            &info.branch,
            target_branch,
            strategy,
            &self.git,
        )
        .await?;

        if result.success {
            let strategy_str = serde_json::to_value(&result.strategy)
                .ok()
                .and_then(|v| v.as_str().map(String::from))
                .unwrap_or_else(|| format!("{:?}", result.strategy).to_lowercase());

            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeMerged,
                payload: json!({
                    "sourceBranch": info.branch,
                    "targetBranch": target_branch,
                    "mergeCommit": result.merge_commit,
                    "strategy": result.strategy
                }),
                parent_id: None,
                sequence: None,
            });

            // Broadcast to WebSocket clients
            self.broadcast(TronEvent::WorktreeMerged {
                base: BaseEvent::now(session_id),
                source_branch: info.branch.clone(),
                target_branch: target_branch.to_string(),
                merge_commit: result.merge_commit.clone(),
                strategy: strategy_str,
            });
        }

        Ok(result)
    }
}
