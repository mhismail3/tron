//! Coordinator-level `finalize_session`: acquires the per-repo lock then
//! delegates to `scm::merge::finalize_session`, and updates in-memory
//! `WorktreeInfo` to reflect the new follow-up branch.
//!
//! Emits `WorktreeSessionFinalized` + `RepoMainAdvanced` on success so
//! other sessions refresh their divergence chips.

use serde_json::json;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::merge as scm_merge;
use crate::worktree::types::{FinalizeSessionResult, MergeStrategy};

use super::WorktreeCoordinator;
use super::repo_lock::LockedOp;

impl WorktreeCoordinator {
    /// Finalise a session: merge its branch into `target_branch`. When
    /// `rebranch` is true (the default), the session's worktree is then
    /// moved onto a fresh `new_branch_name`; when false, the worktree stays
    /// on `source_branch` post-merge and no follow-up branch is created.
    ///
    /// Holds the per-repo lock for the duration.
    #[allow(clippy::too_many_arguments)]
    pub async fn finalize_session(
        &self,
        session_id: &str,
        source_branch: &str,
        target_branch: &str,
        strategy: MergeStrategy,
        new_branch_name: &str,
        preserve_old: bool,
        rebranch: bool,
    ) -> Result<FinalizeSessionResult> {
        let info =
            self.state
                .lock()
                .active_info(session_id)
                .ok_or_else(|| WorktreeError::NotFound {
                    session_id: session_id.to_string(),
                })?;

        let _guard = self
            .acquire_repo_lock(&info.repo_root, session_id, LockedOp::FinalizeSession)
            .await;

        // Snapshot the pre-finalize main HEAD so the broadcast carries
        // the correct before/after. Best-effort — if resolution fails
        // we still emit with an empty old_head rather than skip.
        let pre_head = self
            .git
            .rev_parse_verify(&info.repo_root, target_branch)
            .await
            .unwrap_or_default();

        let result = scm_merge::finalize_session(
            &info.repo_root,
            &info.worktree_path,
            session_id,
            source_branch,
            target_branch,
            strategy.clone(),
            new_branch_name,
            preserve_old,
            rebranch,
            &self.git,
        )
        .await?;

        // Update in-memory WorktreeInfo to point at the new branch.
        {
            let mut state = self.state.lock();
            if let Some(info) = state.active_by_session.get_mut(session_id) {
                info.branch = result.new_branch.clone();
                info.base_commit = result.new_base_commit.clone();
                info.base_branch = Some(target_branch.to_string());
            }
        }

        let strategy_str = strategy.as_str();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeSessionFinalized,
            payload: json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "mergeCommit": result.merge_commit,
                "strategy": strategy_str,
                "newBranch": result.new_branch,
                "newBaseCommit": result.new_base_commit,
                "oldBranchDeleted": result.old_branch_deleted,
                "oldBranchDeleteError": result.old_branch_delete_error,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeSessionFinalized {
            base: BaseEvent::now(session_id),
            source_branch: source_branch.to_string(),
            target_branch: target_branch.to_string(),
            merge_commit: Some(result.merge_commit.clone()),
            strategy: strategy_str.to_string(),
            new_branch: result.new_branch.clone(),
            new_base_commit: result.new_base_commit.clone(),
            old_branch_deleted: result.old_branch_deleted,
            old_branch_delete_error: result.old_branch_delete_error.clone(),
        });

        // Repo-wide broadcast: main advanced.
        let new_head = self
            .git
            .rev_parse_verify(&info.repo_root, target_branch)
            .await
            .unwrap_or_default();
        if !pre_head.is_empty() && !new_head.is_empty() && pre_head != new_head {
            self.broadcast(TronEvent::RepoMainAdvanced {
                base: BaseEvent::now(session_id),
                repo_root: info.repo_root.to_string_lossy().to_string(),
                old_head: pre_head,
                new_head,
                source_session_id: session_id.to_string(),
                cause: "finalize".into(),
            });
        }

        Ok(result)
    }
}
