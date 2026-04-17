use serde_json::json;
use tracing::{debug, instrument, warn};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};

use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::isolation;
use crate::worktree::types::{
    AcquireResult, DeferralReason,
};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Attempt to acquire a worktree for a session.
    ///
    /// Consults isolation policy, creates worktree if needed,
    /// emits `worktree.acquired` event, and tracks state.
    #[instrument(skip(self), fields(session_id, working_dir = %working_dir.display()))]
    pub async fn maybe_acquire(
        &self,
        session_id: &str,
        working_dir: &std::path::Path,
    ) -> Result<AcquireResult> {
        // Idempotent: return existing worktree if still healthy
        let cached = self.state.lock().active_info(session_id);
        if let Some(info) = cached {
            let path_exists = info.worktree_path.exists();
            if path_exists && self.git.is_git_repo(&info.repo_root).await {
                return Ok(AcquireResult::Acquired(info));
            }
            warn!(session_id, "tracked worktree is stale, clearing");
            self.state.lock().untrack(session_id);
            // Fall through to re-evaluate from scratch
        }

        let is_git = self.git.is_git_repo(working_dir).await;
        let repo_count = if is_git {
            if let Ok(root) = self.git.repo_root(working_dir).await {
                self.state.lock().repo_session_count(root.as_ref())
            } else {
                0
            }
        } else {
            0
        };

        if !isolation::should_isolate(&self.config().mode, is_git, repo_count, false) {
            return Ok(AcquireResult::Passthrough);
        }

        // Empty repo guard: git init without commits can't support worktrees
        if !self.git.has_commits(working_dir).await {
            debug!(session_id, "git repo has no commits, deferring worktree creation");
            return Ok(AcquireResult::Deferred(DeferralReason::EmptyRepository));
        }

        let info =
            crate::worktree::lifecycle::create(session_id, working_dir, &self.config, &self.git).await?;

        // Emit event
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeAcquired,
            payload: json!({
                "path": info.worktree_path.to_string_lossy(),
                "branch": info.branch,
                "baseCommit": info.base_commit,
                "baseBranch": info.base_branch,
                "repoRoot": info.repo_root.to_string_lossy(),
                "isolated": true,
                "forkedFrom": null
            }),
            parent_id: None,
            sequence: None,
        });

        // Track
        self.state.lock().track(info.clone());

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeAcquired {
            base: BaseEvent::now(session_id),
            path: info.worktree_path.to_string_lossy().to_string(),
            branch: info.branch.clone(),
            base_commit: info.base_commit.clone(),
            base_branch: info.base_branch.clone(),
        });

        // Emit a generic `metadata.update` so iOS (and any other
        // consumer of the persisted event log) can react to
        // `worktree.active` becoming set without knowing about the
        // specific `WorktreeAcquired` variant.
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::MetadataUpdate,
            payload: json!({
                "key": "worktree.active",
                "newValue": {
                    "path": info.worktree_path.to_string_lossy(),
                    "branch": info.branch,
                    "baseBranch": info.base_branch,
                    "repoRoot": info.repo_root.to_string_lossy(),
                },
            }),
            parent_id: None,
            sequence: None,
        });

        debug!(session_id, branch = %info.branch, "worktree acquired");
        Ok(AcquireResult::Acquired(info))
    }

    /// Release a session's worktree.
    ///
    /// Auto-commits, removes worktree directory, preserves branch per config.
    /// Emits `worktree.released` event.
    #[instrument(skip(self), fields(session_id))]
    pub async fn release(&self, session_id: &str) -> Result<()> {
        let Some(info) = self.state.lock().untrack(session_id) else {
            debug!(session_id, "no active worktree to release");
            return Ok(());
        };

        let release_info = match crate::worktree::lifecycle::remove(&info, &self.config, &self.git).await {
            Ok(release_info) => release_info,
            Err(error) => {
                self.state.lock().track(info);
                return Err(error);
            }
        };

        // Emit event
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeReleased,
            payload: json!({
                "finalCommit": release_info.final_commit,
                "deleted": release_info.deleted,
                "branchPreserved": release_info.branch_preserved,
            }),
            parent_id: None,
            sequence: None,
        });

        // Broadcast to WebSocket clients
        self.broadcast(TronEvent::WorktreeReleased {
            base: BaseEvent::now(session_id),
            final_commit: release_info.final_commit.clone(),
            branch_preserved: release_info.branch_preserved,
            deleted: release_info.deleted,
        });

        // Mirror of the acquire-time metadata.update — clears
        // `worktree.active` so iOS-side state machines can tear down
        // git UI without a dedicated release event handler.
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::MetadataUpdate,
            payload: json!({
                "key": "worktree.active",
                "newValue": serde_json::Value::Null,
            }),
            parent_id: None,
            sequence: None,
        });

        Ok(())
    }

    /// Get the effective working directory for a session.
    ///
    /// Returns the worktree path if active, None otherwise.
    pub fn effective_working_dir(&self, session_id: &str) -> Option<String> {
        self.state
            .lock()
            .active_info(session_id)
            .map(|info| info.worktree_path.to_string_lossy().to_string())
    }

    /// Rename the branch of an active worktree.
    ///
    /// Renames the git branch, updates coordinator state, emits `worktree.renamed`
    /// event, and broadcasts to WebSocket clients. No-op if `new_branch` equals
    /// the current branch name.
    #[instrument(skip(self), fields(session_id, new_branch))]
    pub async fn rename_branch(&self, session_id: &str, new_branch: &str) -> Result<()> {
        let info = self.state.lock().active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        let old_branch = info.branch.clone();

        if old_branch == new_branch {
            return Ok(());
        }

        self.git.branch_rename(&info.repo_root, &old_branch, new_branch).await?;

        {
            let mut state = self.state.lock();
            if let Some(tracked) = state.active_by_session.get_mut(session_id) {
                tracked.branch = new_branch.to_string();
            }
        }

        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeRenamed,
            payload: json!({
                "oldBranch": old_branch,
                "newBranch": new_branch,
            }),
            parent_id: None,
            sequence: None,
        });

        self.broadcast(TronEvent::WorktreeRenamed {
            base: BaseEvent::now(session_id),
            old_branch: old_branch.clone(),
            new_branch: new_branch.to_string(),
        });

        tracing::info!(session_id, old = %old_branch, new = %new_branch, "branch renamed");
        Ok(())
    }
}
