//! Coordinator-level wrappers around the conflict state machine in
//! `scm::conflict`.
//!
//! Mutates `state.pending_merges` so the coordinator (and crash recovery)
//! can track in-flight merges per session. Emits `worktree.merge_started`,
//! `worktree.conflict_detected`, `worktree.conflict_resolved`,
//! `worktree.merge_continued`, `worktree.merge_aborted` so iOS can
//! surface lifecycle progress.
//!
//! ## Unified conflict model
//!
//! Every conflict scenario — `Finalize` (session→main), `RebaseOnMain`
//! (main→session), and `StashPop` (post-rebase stash carry-over) — flows
//! through the same `pending_merges` entry + the same RPC surface:
//! `listConflicts` / `resolveConflict` / `continueMerge` / `abortMerge`.
//! Origin drives only the continue/abort side effects:
//!
//! | Origin        | continue_merge side effect       | abort_merge side effect            |
//! |---------------|----------------------------------|------------------------------------|
//! | Finalize      | `git merge --continue`           | `git merge --abort`                |
//! | RebaseOnMain  | `git rebase --continue` + pop stash | `git rebase --abort` + pop stash |
//! | StashPop      | `git stash drop <ref>`           | `git reset --hard HEAD` (stash kept) |
//!
//! StashPop has no on-disk merge/rebase state (`.git/MERGE_HEAD` /
//! `.git/rebase-merge` are absent); conflicts live purely in the index as
//! unmerged entries from a conflicted `git stash pop`.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::conflict as scm_conflict;
use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::types::{
    ConflictResolution, ConflictedFile, MergeOrigin, MergeStrategy, PendingMergeState,
};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Start a merge/rebase that keeps conflict state on disk until the
    /// caller explicitly resolves and continues (or aborts).
    ///
    /// Used by the finalize workflow (`worktree.startMerge`) — origin is
    /// pinned to `MergeOrigin::Finalize`. `rebase_on_main` has its own
    /// path because it owns extra lifecycle (stash carry-over + lock).
    pub async fn start_merge_keep_conflicts(
        &self,
        session_id: &str,
        source_branch: &str,
        target_branch: &str,
        strategy: MergeStrategy,
    ) -> Result<PendingMergeState> {
        let info =
            self.state
                .lock()
                .active_info(session_id)
                .ok_or_else(|| WorktreeError::NotFound {
                    session_id: session_id.to_string(),
                })?;

        let pending = scm_conflict::start_merge_keep_conflicts(
            &info.repo_root,
            session_id,
            source_branch,
            target_branch,
            strategy.clone(),
            MergeOrigin::Finalize,
            &self.git,
        )
        .await?;

        self.state
            .lock()
            .pending_merges
            .insert(session_id.to_string(), pending.clone());

        // Probe the in-flight merge's conflict paths so the event carries
        // actionable payload. Best-effort — on failure emit with empty list.
        let paths: Vec<String> =
            scm_conflict::list_conflicts(&info.repo_root, strategy.clone(), &self.git)
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
            emit_conflict_detected(
                self,
                session_id,
                source_branch,
                target_branch,
                MergeOrigin::Finalize,
                &paths,
            );
        }

        Ok(pending)
    }

    /// List conflicts for `session_id`'s in-flight merge.
    pub async fn list_conflicts(&self, session_id: &str) -> Result<Vec<ConflictedFile>> {
        let (working_dir, strategy) = self.merge_context(session_id)?;
        scm_conflict::list_conflicts(&working_dir, strategy, &self.git).await
    }

    /// Apply `resolution` to a single conflicted path.
    pub async fn resolve_conflict(
        &self,
        session_id: &str,
        path: &str,
        resolution: ConflictResolution,
    ) -> Result<()> {
        let (working_dir, _strategy) = self.merge_context(session_id)?;
        scm_conflict::resolve_conflict(&working_dir, path, resolution.clone(), &self.git).await?;

        // Count remaining after the resolution.
        let remaining = scm_conflict::list_conflicts(&working_dir, _strategy.clone(), &self.git)
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
    ///
    /// Dispatches on `pending.origin`:
    /// - `Finalize` — `git <strategy> --continue`; emit `merge_continued`.
    /// - `RebaseOnMain` — `git rebase --continue`, then pop auto-stash
    ///   (may re-surface conflicts via `handle_post_stash_pop`); emit
    ///   `merge_continued` then `rebased_on_main`.
    /// - `StashPop` — drop the stash (unmerged index entries are already
    ///   resolved by `resolve_conflict`); emit `merge_continued` with
    ///   origin = `stash_pop`.
    pub async fn continue_merge(&self, session_id: &str, message: Option<&str>) -> Result<String> {
        let pending_snapshot = self
            .state
            .lock()
            .pending_merges
            .get(session_id)
            .cloned()
            .ok_or(WorktreeError::NoPendingMerge)?;

        if pending_snapshot.origin == MergeOrigin::StashPop {
            return self.continue_stash_pop(session_id, &pending_snapshot).await;
        }

        let (working_dir, strategy) = self.merge_context(session_id)?;
        let sha = scm_conflict::continue_merge(&working_dir, strategy.clone(), message, &self.git)
            .await?;
        self.state.lock().pending_merges.remove(session_id);

        let strategy_str = strategy.as_str().to_string();
        let origin_str = pending_snapshot.origin.as_str().to_string();
        emit_merge_continued(self, session_id, &sha, &strategy_str, &origin_str);

        // RebaseOnMain carry-over: pop stash + emit rebased_on_main.
        // `working_dir` is already `info.worktree_path` per `merge_context`
        // for the RebaseOnMain origin — no need to re-look it up.
        if pending_snapshot.origin == MergeOrigin::RebaseOnMain {
            let worktree_path = &working_dir;
            let had_auto_stash = pending_snapshot.auto_stash_ref.is_some();
            if let Some(ref stash_ref) = pending_snapshot.auto_stash_ref {
                let pop_result = self.git.stash_pop(worktree_path, stash_ref).await;
                // If pop conflicts, helper re-populates pending_merges with
                // StashPop origin so the user has a resolver path.
                self.handle_post_stash_pop(session_id, stash_ref, pop_result);
            }
            let _ = super::rebase_on_main::remove_sidecar(worktree_path, session_id).await;

            // Compute new base commit.
            let new_base_commit = self
                .git
                .head_commit(worktree_path)
                .await
                .unwrap_or_default();
            {
                let mut state = self.state.lock();
                if let Some(info) = state.active_by_session.get_mut(session_id) {
                    info.base_commit = new_base_commit.clone();
                }
            }

            // `mainCommitsIncorporated` is best-effort: we don't have a
            // pre-merge snapshot here, so emit 0 and let iOS refresh
            // divergence via `repo.getDivergence`. The initial clean-path
            // `rebased_on_main` already carried the accurate number.
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeRebasedOnMain,
                payload: json!({
                    "mainBranch": pending_snapshot.target_branch,
                    "strategy": strategy_str,
                    "oldBaseCommit": "",
                    "newBaseCommit": new_base_commit,
                    "mainCommitsIncorporated": 0u64,
                    "hadAutoStash": had_auto_stash,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreeRebasedOnMain {
                base: BaseEvent::now(session_id),
                main_branch: pending_snapshot.target_branch.clone(),
                strategy: strategy_str,
                old_base_commit: String::new(),
                new_base_commit,
                main_commits_incorporated: 0,
                had_auto_stash,
            });
        }

        Ok(sha)
    }

    /// `continue_merge` branch for `MergeOrigin::StashPop` — the stash pop
    /// produced unmerged entries which have since been resolved. There is
    /// no `.git/MERGE_HEAD` / `.git/rebase-merge` to continue; we just
    /// drop the stash (its content now lives in the working tree + index)
    /// and clear pending state.
    async fn continue_stash_pop(
        &self,
        session_id: &str,
        pending: &PendingMergeState,
    ) -> Result<String> {
        let worktree_path = self
            .state
            .lock()
            .active_info(session_id)
            .map(|i| i.worktree_path)
            .ok_or_else(|| WorktreeError::NotFound {
                session_id: session_id.to_string(),
            })?;

        // Reject continue if there are still unmerged paths.
        let remaining = self
            .git
            .conflict_files(&worktree_path)
            .await
            .unwrap_or_default();
        if !remaining.is_empty() {
            return Err(WorktreeError::Git(format!(
                "cannot continue: {} unresolved file(s): {}",
                remaining.len(),
                remaining.join(", ")
            )));
        }

        // StashPop pending_merge is populated via `handle_post_stash_pop`
        // which always sets `auto_stash_ref = Some(_)`. Missing here means
        // a coordinator-level bug — surface it as an error rather than
        // silently dropping the wrong stash.
        let stash_ref = pending.auto_stash_ref.as_deref().ok_or_else(|| {
            WorktreeError::InvalidSessionState(
                "StashPop pending_merge missing auto_stash_ref".into(),
            )
        })?;
        // `git stash drop` is idempotent via `GitExecutor::stash_drop`
        // (already-gone ref returns `Ok(())`), so we just propagate any
        // genuine I/O error.
        self.git.stash_drop(&worktree_path, stash_ref).await?;

        let _ = super::rebase_on_main::remove_sidecar(&worktree_path, session_id).await;
        self.state.lock().pending_merges.remove(session_id);

        let head = self
            .git
            .head_commit(&worktree_path)
            .await
            .unwrap_or_default();
        // Strategy field is a dummy (`"merge"`) — StashPop has no real
        // strategy. iOS branches on `origin`.
        emit_merge_continued(self, session_id, &head, "merge", "stash_pop");
        Ok(head)
    }

    /// Abort an in-progress merge.
    pub async fn abort_merge(&self, session_id: &str) -> Result<()> {
        self.abort_merge_with_reason(session_id, "user").await
    }

    /// Abort an in-progress merge with an explicit reason code.
    ///
    /// Used by the conflict-resolver subagent handoff (phase 7) to
    /// distinguish user-driven aborts from subagent failures.
    ///
    /// Dispatches on `pending.origin`:
    /// - `Finalize` / `RebaseOnMain` — `git merge --abort` / `rebase --abort`;
    ///   for `RebaseOnMain`, also pops the auto-stash (restoring dirty state).
    /// - `StashPop` — `git reset --hard HEAD`; the stash stays on the stash
    ///   stack so the user can retry or drop it manually.
    pub async fn abort_merge_with_reason(&self, session_id: &str, reason: &str) -> Result<()> {
        let pending_snapshot = self
            .state
            .lock()
            .pending_merges
            .get(session_id)
            .cloned()
            .ok_or(WorktreeError::NoPendingMerge)?;

        if pending_snapshot.origin == MergeOrigin::StashPop {
            return self.abort_stash_pop(session_id, reason).await;
        }

        let (working_dir, strategy) = self.merge_context(session_id)?;
        scm_conflict::abort_conflict_merge(&working_dir, strategy.clone(), &self.git).await?;
        self.state.lock().pending_merges.remove(session_id);

        let strategy_str = strategy.as_str().to_string();
        let origin_str = pending_snapshot.origin.as_str().to_string();
        emit_merge_aborted(self, session_id, &strategy_str, reason, &origin_str);

        // RebaseOnMain carry-over: pop stash (restores dirty state).
        // `working_dir` is already `info.worktree_path` per `merge_context`.
        if pending_snapshot.origin == MergeOrigin::RebaseOnMain {
            let worktree_path = &working_dir;
            if let Some(ref stash_ref) = pending_snapshot.auto_stash_ref {
                let pop_result = self.git.stash_pop(worktree_path, stash_ref).await;
                self.handle_post_stash_pop(session_id, stash_ref, pop_result);
            }
            let _ = super::rebase_on_main::remove_sidecar(worktree_path, session_id).await;
        }
        Ok(())
    }

    /// `abort_merge` branch for `MergeOrigin::StashPop` — reset the working
    /// tree + index to HEAD to discard the half-applied stash. The stash
    /// itself stays on the stack so the user can retry or drop it manually.
    async fn abort_stash_pop(&self, session_id: &str, reason: &str) -> Result<()> {
        let worktree_path = self
            .state
            .lock()
            .active_info(session_id)
            .map(|i| i.worktree_path)
            .ok_or_else(|| WorktreeError::NotFound {
                session_id: session_id.to_string(),
            })?;

        self.git.reset_hard(&worktree_path, "HEAD").await?;

        let _ = super::rebase_on_main::remove_sidecar(&worktree_path, session_id).await;
        self.state.lock().pending_merges.remove(session_id);

        emit_merge_aborted(self, session_id, "merge", reason, "stash_pop");
        Ok(())
    }

    /// Shared handler for a post-rebase `git stash pop` result.
    ///
    /// Called from three sites:
    /// 1. `rebase_on_main` clean path (direct pop after rebase).
    /// 2. `continue_merge(RebaseOnMain)` (pop after conflict resolution).
    /// 3. `abort_merge(RebaseOnMain)` (pop to restore dirty state).
    ///
    /// On non-empty conflicts, populates `pending_merges` with a
    /// `StashPop` entry so the user has an immediate resolver path, and
    /// emits both `post_rebase_stash_conflict` (informational, carries
    /// stash_ref) and `conflict_detected` (drives the iOS unified banner).
    pub(super) fn handle_post_stash_pop(
        &self,
        session_id: &str,
        stash_ref: &str,
        result: Result<Vec<String>>,
    ) {
        match result {
            Ok(conflicts) if conflicts.is_empty() => {}
            Ok(conflicts) => {
                let now_ms = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);

                // Session branch — used only for event source/target
                // fields; informational.
                let session_branch = self
                    .state
                    .lock()
                    .active_info(session_id)
                    .map(|i| i.branch.clone())
                    .unwrap_or_default();

                self.state.lock().pending_merges.insert(
                    session_id.to_string(),
                    PendingMergeState {
                        session_id: session_id.to_string(),
                        source_branch: "stash".into(),
                        target_branch: session_branch.clone(),
                        strategy: MergeStrategy::Merge,
                        started_at_ms: now_ms,
                        crash_recovered: false,
                        origin: MergeOrigin::StashPop,
                        auto_stash_ref: Some(stash_ref.to_string()),
                    },
                );

                // Emit post_rebase_stash_conflict — informational event
                // carrying the stash ref for logging / diagnostics.
                self.broadcast(TronEvent::WorktreePostRebaseStashConflict {
                    base: BaseEvent::now(session_id),
                    stash_ref: stash_ref.to_string(),
                    paths: conflicts.clone(),
                });
                let _ = self.event_store.append(&AppendOptions {
                    session_id,
                    event_type: EventType::WorktreePostRebaseStashConflict,
                    payload: json!({
                        "stashRef": stash_ref,
                        "paths": conflicts,
                    }),
                    parent_id: None,
                    sequence: None,
                });

                // Emit conflict_detected — drives the iOS unified
                // conflict banner (`gitWorkflowState.conflictBanner`).
                emit_conflict_detected(
                    self,
                    session_id,
                    "stash",
                    &session_branch,
                    MergeOrigin::StashPop,
                    &conflicts,
                );
            }
            Err(e) => {
                tracing::warn!(session_id, error = %e, "stash_pop errored post-rebase");
            }
        }
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
        let (working_dir, strategy) = self.merge_context(session_id)?;
        let worktree_path = self
            .state
            .lock()
            .active_info(session_id)
            .map(|i| i.worktree_path)
            .ok_or_else(|| WorktreeError::NotFound {
                session_id: session_id.to_string(),
            })?;

        // StashPop is "done" when no unmerged paths remain; the subagent
        // never calls `git merge --continue` / `rebase --continue` here.
        let pending = self
            .state
            .lock()
            .pending_merges
            .get(session_id)
            .cloned()
            .ok_or(WorktreeError::NoPendingMerge)?;

        if pending.origin == MergeOrigin::StashPop {
            let unmerged = self
                .git
                .conflict_files(&worktree_path)
                .await
                .unwrap_or_default();
            if !unmerged.is_empty() {
                return Ok(false);
            }
            // StashPop pending is populated with `auto_stash_ref = Some(_)`
            // by `handle_post_stash_pop`; missing means a coordinator bug.
            let stash_ref = pending.auto_stash_ref.as_deref().ok_or_else(|| {
                WorktreeError::InvalidSessionState(
                    "StashPop pending_merge missing auto_stash_ref".into(),
                )
            })?;
            self.git.stash_drop(&worktree_path, stash_ref).await?;
            let _ = super::rebase_on_main::remove_sidecar(&worktree_path, session_id).await;
            let head = self
                .git
                .head_commit(&worktree_path)
                .await
                .unwrap_or_default();
            self.state.lock().pending_merges.remove(session_id);
            emit_merge_continued(self, session_id, &head, "merge", "stash_pop");
            return Ok(true);
        }

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
        let origin_str = pending.origin.as_str().to_string();
        emit_merge_continued(self, session_id, &sha, &strategy_str, &origin_str);
        // Silence unused in case no working_dir consumer above touches it.
        let _ = working_dir;
        Ok(true)
    }

    /// Resolve `(working_dir, strategy)` for a session's in-flight merge.
    ///
    /// Returns `NoPendingMerge` when the session has no tracked pending
    /// merge; callers must not silently default the strategy (doing so
    /// would run the wrong `--continue` / `--abort` path for rebase/squash
    /// merges). Crash recovery reconstructs `pending_merges` at startup so
    /// this is safe once the coordinator is up.
    ///
    /// `working_dir` depends on the pending merge's origin:
    /// - `MergeOrigin::Finalize` — `info.repo_root` (merge landed on
    ///   main in the repo root).
    /// - `MergeOrigin::RebaseOnMain` — `info.worktree_path` (rebase/merge
    ///   happened inside the session's linked worktree).
    /// - `MergeOrigin::StashPop` — `info.worktree_path` (unmerged paths
    ///   live in the worktree's index; no cross-worktree state).
    fn merge_context(&self, session_id: &str) -> Result<(std::path::PathBuf, MergeStrategy)> {
        let state = self.state.lock();
        let info = state
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound {
                session_id: session_id.to_string(),
            })?;
        let pending = state
            .pending_merges
            .get(session_id)
            .ok_or(WorktreeError::NoPendingMerge)?;
        let working_dir = match pending.origin {
            MergeOrigin::Finalize => info.repo_root.clone(),
            MergeOrigin::RebaseOnMain | MergeOrigin::StashPop => info.worktree_path.clone(),
        };
        Ok((working_dir, pending.strategy.clone()))
    }
}

/// Emit `worktree.conflict_detected` with the unified origin field.
fn emit_conflict_detected(
    coord: &WorktreeCoordinator,
    session_id: &str,
    source_branch: &str,
    target_branch: &str,
    origin: MergeOrigin,
    paths: &[String],
) {
    let origin_str = origin.as_str();
    let _ = coord.event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::WorktreeConflictDetected,
        payload: json!({
            "sourceBranch": source_branch,
            "targetBranch": target_branch,
            "origin": origin_str,
            "paths": paths,
        }),
        parent_id: None,
        sequence: None,
    });
    coord.broadcast(TronEvent::WorktreeConflictDetected {
        base: BaseEvent::now(session_id),
        source_branch: source_branch.to_string(),
        target_branch: target_branch.to_string(),
        origin: origin_str.to_string(),
        paths: paths.to_vec(),
    });
}

/// Emit `worktree.merge_continued` with origin discriminator.
fn emit_merge_continued(
    coord: &WorktreeCoordinator,
    session_id: &str,
    sha: &str,
    strategy: &str,
    origin: &str,
) {
    let _ = coord.event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::WorktreeMergeContinued,
        payload: json!({
            "mergeCommit": sha,
            "strategy": strategy,
            "origin": origin,
        }),
        parent_id: None,
        sequence: None,
    });
    coord.broadcast(TronEvent::WorktreeMergeContinued {
        base: BaseEvent::now(session_id),
        merge_commit: sha.to_string(),
        strategy: strategy.to_string(),
        origin: origin.to_string(),
    });
}

/// Emit `worktree.merge_aborted` with origin discriminator.
fn emit_merge_aborted(
    coord: &WorktreeCoordinator,
    session_id: &str,
    strategy: &str,
    reason: &str,
    origin: &str,
) {
    let _ = coord.event_store.append(&AppendOptions {
        session_id,
        event_type: EventType::WorktreeMergeAborted,
        payload: json!({
            "strategy": strategy,
            "reason": reason,
            "origin": origin,
        }),
        parent_id: None,
        sequence: None,
    });
    coord.broadcast(TronEvent::WorktreeMergeAborted {
        base: BaseEvent::now(session_id),
        strategy: strategy.to_string(),
        reason: reason.to_string(),
        origin: origin.to_string(),
    });
}
