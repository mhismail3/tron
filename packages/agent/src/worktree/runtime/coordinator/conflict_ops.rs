//! Coordinator-level wrappers around the conflict state machine in
//! `scm::conflict`.
//!
//! Mutates `state.pending_merges` so the coordinator (and crash recovery)
//! can track in-flight merges per session. Emits `worktree.merge_started`,
//! `worktree.conflict_detected`, `worktree.conflict_resolved`,
//! `worktree.merge_continued`, `worktree.merge_aborted` so iOS can
//! surface lifecycle progress.

use serde_json::json;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::conflict as scm_conflict;
use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::types::{
    ConflictResolution, ConflictedFile, MergeStrategy, PendingMergeState,
};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Start a merge/rebase that keeps conflict state on disk until the
    /// caller explicitly resolves and continues (or aborts).
    pub async fn start_merge_keep_conflicts(
        &self,
        session_id: &str,
        source_branch: &str,
        target_branch: &str,
        strategy: MergeStrategy,
    ) -> Result<PendingMergeState> {
        let info = self
            .state
            .lock()
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        let pending = scm_conflict::start_merge_keep_conflicts(
            &info.repo_root,
            session_id,
            source_branch,
            target_branch,
            strategy.clone(),
            &self.git,
        )
        .await?;

        self.state
            .lock()
            .pending_merges
            .insert(session_id.to_string(), pending.clone());

        // Probe the in-flight merge's conflict paths so the event carries
        // actionable payload. Best-effort — on failure emit with empty list.
        let paths: Vec<String> = scm_conflict::list_conflicts(
            &info.repo_root,
            strategy.clone(),
            &self.git,
        )
        .await
        .map(|v| v.into_iter().map(|c| c.path).collect())
        .unwrap_or_default();
        let strategy_str = strategy.as_str().to_string();
        let conflict_count = paths.len() as u32;

        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeMergeStarted,
            payload: json!({
                "sourceBranch": source_branch,
                "targetBranch": target_branch,
                "strategy": strategy_str,
                "conflictCount": conflict_count,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeMergeStarted {
            base: BaseEvent::now(session_id),
            source_branch: source_branch.to_string(),
            target_branch: target_branch.to_string(),
            strategy: strategy_str,
            conflict_count,
        });

        if conflict_count > 0 {
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeConflictDetected,
                payload: json!({
                    "sourceBranch": source_branch,
                    "targetBranch": target_branch,
                    "paths": paths,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreeConflictDetected {
                base: BaseEvent::now(session_id),
                source_branch: source_branch.to_string(),
                target_branch: target_branch.to_string(),
                paths,
            });
        }

        Ok(pending)
    }

    /// List conflicts for `session_id`'s in-flight merge.
    pub async fn list_conflicts(&self, session_id: &str) -> Result<Vec<ConflictedFile>> {
        let (repo_root, strategy) = self.merge_context(session_id)?;
        scm_conflict::list_conflicts(&repo_root, strategy, &self.git).await
    }

    /// Apply `resolution` to a single conflicted path.
    pub async fn resolve_conflict(
        &self,
        session_id: &str,
        path: &str,
        resolution: ConflictResolution,
    ) -> Result<()> {
        let (repo_root, _strategy) = self.merge_context(session_id)?;
        scm_conflict::resolve_conflict(&repo_root, path, resolution.clone(), &self.git).await?;

        // Count remaining after the resolution.
        let remaining = scm_conflict::list_conflicts(&repo_root, _strategy.clone(), &self.git)
            .await
            .map(|v| v.len())
            .unwrap_or(0) as u32;
        let resolution_str = resolution.as_str().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeConflictResolved,
            payload: json!({
                "path": path,
                "resolution": resolution_str,
                "remaining": remaining,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeConflictResolved {
            base: BaseEvent::now(session_id),
            path: path.to_string(),
            resolution: resolution_str,
            remaining,
        });
        Ok(())
    }

    /// Finalise an in-progress merge after all conflicts are resolved.
    pub async fn continue_merge(
        &self,
        session_id: &str,
        message: Option<&str>,
    ) -> Result<String> {
        let (repo_root, strategy) = self.merge_context(session_id)?;
        let sha =
            scm_conflict::continue_merge(&repo_root, strategy.clone(), message, &self.git).await?;
        self.state.lock().pending_merges.remove(session_id);

        let strategy_str = strategy.as_str().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeMergeContinued,
            payload: json!({
                "mergeCommit": sha,
                "strategy": strategy_str,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeMergeContinued {
            base: BaseEvent::now(session_id),
            merge_commit: sha.clone(),
            strategy: strategy_str,
        });
        Ok(sha)
    }

    /// Abort an in-progress merge.
    pub async fn abort_merge(&self, session_id: &str) -> Result<()> {
        self.abort_merge_with_reason(session_id, "user").await
    }

    /// Abort an in-progress merge with an explicit reason code.
    ///
    /// Used by the conflict-resolver subagent handoff (phase 7) to
    /// distinguish user-driven aborts from subagent failures.
    pub async fn abort_merge_with_reason(
        &self,
        session_id: &str,
        reason: &str,
    ) -> Result<()> {
        let (repo_root, strategy) = self.merge_context(session_id)?;
        scm_conflict::abort_conflict_merge(&repo_root, strategy.clone(), &self.git).await?;
        self.state.lock().pending_merges.remove(session_id);

        let strategy_str = strategy.as_str().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeMergeAborted,
            payload: json!({
                "strategy": strategy_str,
                "reason": reason,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeMergeAborted {
            base: BaseEvent::now(session_id),
            strategy: strategy_str,
            reason: reason.to_string(),
        });
        Ok(())
    }

    /// Inspect tracked pending merges (for RPC / crash recovery).
    pub fn pending_merge(&self, session_id: &str) -> Option<PendingMergeState> {
        self.state.lock().pending_merges.get(session_id).cloned()
    }

    /// Reconcile in-memory pending-merge state with the on-disk state.
    ///
    /// Used after a subagent (e.g. the conflict resolver) may have
    /// completed a merge via raw `git` commands — which resolves the
    /// on-disk merge but leaves the coordinator's `pending_merges` cache
    /// stale. This method inspects the worktree; if no merge/rebase is
    /// in progress anymore it clears the cache entry and emits
    /// `WorktreeMergeContinued` with the current HEAD so iOS sees the
    /// same lifecycle it would have seen via `continue_merge`.
    ///
    /// Returns:
    /// - `Ok(true)` — cache had an entry and the merge is complete;
    ///   state reconciled.
    /// - `Ok(false)` — cache had an entry but the merge is still in
    ///   progress on disk; caller should abort.
    /// - `Err(NoPendingMerge)` — no cache entry for this session.
    pub async fn reconcile_completed_merge(&self, session_id: &str) -> Result<bool> {
        let (repo_root, strategy) = self.merge_context(session_id)?;
        let worktree_path = self
            .state
            .lock()
            .active_info(session_id)
            .map(|i| i.worktree_path)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;

        // Probe the actual on-disk state (not the cache).
        let merge_in_progress = self
            .git
            .has_merge_in_progress(&worktree_path)
            .await
            .unwrap_or(true);
        let rebase_in_progress = self
            .git
            .has_rebase_in_progress(&worktree_path)
            .await
            .unwrap_or(true);
        if merge_in_progress || rebase_in_progress {
            return Ok(false);
        }

        // Merge is done on disk — reconcile cache + emit the
        // merge-continued lifecycle event.
        let sha = self
            .git
            .head_commit(&worktree_path)
            .await
            .unwrap_or_default();
        self.state.lock().pending_merges.remove(session_id);

        let strategy_str = strategy.as_str().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeMergeContinued,
            payload: json!({
                "mergeCommit": sha,
                "strategy": strategy_str,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeMergeContinued {
            base: BaseEvent::now(session_id),
            merge_commit: sha,
            strategy: strategy_str,
        });
        // Silence unused in case no repo_root consumer above touches it.
        let _ = repo_root;
        Ok(true)
    }

    /// Resolve `(repo_root, strategy)` for a session's in-flight merge.
    ///
    /// Returns `NoPendingMerge` when the session has no tracked pending
    /// merge; callers must not silently default the strategy (doing so
    /// would run the wrong `--continue` / `--abort` path for rebase/squash
    /// merges). Crash recovery reconstructs `pending_merges` at startup so
    /// this is safe once the coordinator is up.
    fn merge_context(
        &self,
        session_id: &str,
    ) -> Result<(std::path::PathBuf, MergeStrategy)> {
        let state = self.state.lock();
        let info = state
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound(session_id.to_string()))?;
        let strategy = state
            .pending_merges
            .get(session_id)
            .map(|p| p.strategy.clone())
            .ok_or(WorktreeError::NoPendingMerge)?;
        Ok((info.repo_root, strategy))
    }
}

