use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tracing::{debug, info, warn};

use crate::domains::session::event_store::sqlite::repositories::session::ListSessionsOptions;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::domains::worktree::types::WorktreeInfo;
use crate::shared::events::{BaseEvent, TronEvent};

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Rebuild active worktree state from persisted events.
    ///
    /// Scans for sessions with `worktree.acquired` events (without a subsequent
    /// `worktree.released`) and re-populates the in-memory state.
    /// Must be called before `recover_orphans` to prevent deleting valid worktrees.
    pub fn rebuild_from_events(&self) {
        let sessions = self
            .event_store
            .list_sessions(&ListSessionsOptions {
                ended: Some(false),
                ..Default::default()
            })
            .unwrap_or_default();

        let mut restored_infos = Vec::new();
        for session in &sessions {
            let Ok(Some(acq)) = self.event_store.get_active_worktree(&session.id) else {
                continue;
            };

            let payload: serde_json::Value = match serde_json::from_str(&acq.payload) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let branch = payload["branch"].as_str().unwrap_or_default();
            let base_commit = payload["baseCommit"].as_str().unwrap_or_default();
            let path = payload["path"].as_str().unwrap_or_default();
            let repo_root = payload["repoRoot"].as_str().unwrap_or_default();
            let base_branch = payload["baseBranch"].as_str().map(String::from);

            if branch.is_empty() || path.is_empty() {
                continue;
            }

            // Only restore if the worktree directory still exists
            let wt_path = PathBuf::from(path);
            if !wt_path.exists() {
                debug!(session_id = %session.id, path, "worktree dir gone, skipping rebuild");
                continue;
            }

            let info = WorktreeInfo {
                session_id: session.id.clone(),
                worktree_path: wt_path,
                branch: branch.to_string(),
                base_commit: base_commit.to_string(),
                original_working_dir: PathBuf::from(&session.working_directory),
                repo_root: PathBuf::from(repo_root),
                base_branch,
            };

            restored_infos.push(info);
        }

        // Apply rename events to get final branch names
        for info in &mut restored_infos {
            let renamed = self
                .event_store
                .get_events_by_type(&info.session_id, &["worktree.renamed"], None)
                .unwrap_or_default();
            if let Some(last) = renamed.last() {
                if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&last.payload) {
                    if let Some(new_branch) = payload["newBranch"].as_str() {
                        info.branch = new_branch.to_string();
                    }
                }
            }
        }

        let restored = restored_infos.len();
        self.state.lock().replace_active(restored_infos);

        if restored > 0 {
            info!(restored, "rebuilt active worktrees from events");
        }
    }

    /// Recover orphaned worktrees across all known workspaces.
    ///
    /// Called on server startup (fire-and-forget).
    /// IMPORTANT: Call `rebuild_from_events` first to avoid deleting valid worktrees.
    pub async fn recover_orphans(&self) -> usize {
        let workspaces = self.event_store.list_workspaces().unwrap_or_default();
        let active_branches: HashSet<String> = self
            .state
            .lock()
            .active_by_session
            .values()
            .map(|info| info.branch.clone())
            .collect();

        let mut total = 0;
        for ws in &workspaces {
            let repo_root = PathBuf::from(&ws.path);
            if !self.git.is_git_repo(&repo_root).await {
                continue;
            }
            match crate::domains::worktree::recovery::recover_repo(
                &repo_root,
                &active_branches,
                &self.config,
                &self.git,
            )
            .await
            {
                Ok(recovered) => {
                    // Surface auto-commit SHAs so iOS can offer the
                    // user a notice with a recoverable commit. Only
                    // orphaned sessions with a parseable session_id
                    // and a persisted session row get the event —
                    // branches whose session was fully removed from
                    // the DB have no timeline to attach to.
                    for rec in &recovered {
                        let Some(ref sha) = rec.auto_committed_sha else {
                            continue;
                        };
                        let Some(session_id) = rec.branch.strip_prefix(&self.config.branch_prefix)
                        else {
                            continue;
                        };
                        if session_id.is_empty() {
                            continue;
                        }
                        if self
                            .event_store
                            .get_session(session_id)
                            .ok()
                            .flatten()
                            .is_none()
                        {
                            continue;
                        }
                        let _ = self.event_store.append(&AppendOptions {
                            session_id,
                            event_type: EventType::WorktreeAutoRecoveredCommits,
                            payload: json!({
                                "branch": rec.branch,
                                "commitHash": sha,
                                "path": rec.path,
                                "branchRemoved": rec.branch_deleted,
                            }),
                            parent_id: None,
                            sequence: None,
                        });
                        self.broadcast(TronEvent::WorktreeAutoRecoveredCommits {
                            base: BaseEvent::now(session_id),
                            branch: rec.branch.clone(),
                            commit_hash: sha.clone(),
                            path: rec.path.clone(),
                            branch_removed: rec.branch_deleted,
                        });
                    }
                    total += recovered.len();
                }
                Err(e) => {
                    warn!(repo = %repo_root.display(), error = %e, "orphan recovery failed");
                }
            }
        }

        if total > 0 {
            info!(total, "orphan worktrees recovered");
        }
        total
    }

    /// Scan active worktrees for in-progress merges/rebases left behind
    /// by a crashed server, reconstruct `pending_merges`, emit
    /// `worktree.pending_merge_detected` so iOS can render a banner, and
    /// arm an auto-abort timer so half-merged sessions can't linger.
    ///
    /// Also scans for `rebase_on_main` sidecars (
    /// `.git/tron-rebase-stash-<sid>.json`) and reconciles them against
    /// the on-disk merge state:
    /// - sidecar + merge/rebase in progress → rebuild with
    ///   `auto_stash_ref` + `origin = RebaseOnMain`
    /// - sidecar + no merge/rebase → orphan stash; pop it to restore the
    ///   pre-op dirty state and clean up the sidecar (either the rebase
    ///   succeeded and we crashed before popping, OR the rebase never
    ///   started — the restored state is valid either way)
    /// - no sidecar + merge/rebase in progress → existing finalize path
    /// - no sidecar + no merge/rebase → nothing to do
    ///
    /// Call after `rebuild_from_events` so active worktrees are populated.
    pub async fn rebuild_pending_merges(self: &Arc<Self>) -> usize {
        let infos: Vec<WorktreeInfo> = self
            .state
            .lock()
            .active_by_session
            .values()
            .cloned()
            .collect();

        let mut restored = 0usize;
        for info in infos {
            // Read any rebase_on_main sidecar first so we can overlay
            // its metadata on the reconstructed PendingMergeState.
            let sidecars =
                super::rebase_on_main::read_sidecars_for_worktree(&info.worktree_path).await;
            let sidecar_for_session = sidecars
                .into_iter()
                .find(|(sid, _)| sid == &info.session_id)
                .and_then(|(_, c)| c);

            let reconstructed =
                crate::domains::worktree::recovery::reconstruct_pending_merge(&info, &self.git)
                    .await;

            let pending = match (reconstructed, sidecar_for_session.as_ref()) {
                (None, None) => continue,
                (None, Some(sc)) => {
                    // No on-disk merge / rebase state — but there might
                    // still be unresolved index entries from a previously
                    // attempted (and conflicted) stash pop. Probe the
                    // index first.
                    let unmerged = self
                        .git
                        .conflict_files(&info.worktree_path)
                        .await
                        .unwrap_or_default();
                    if !unmerged.is_empty() {
                        // Previous stash pop conflicted; conflicts were
                        // never resolved. Synthesise a StashPop pending
                        // merge via the shared helper so the resolver UX
                        // lights up. Keep the sidecar (it's still valid).
                        self.handle_post_stash_pop(&info.session_id, &sc.stash_ref, Ok(unmerged));
                        restored += 1;
                        continue;
                    }
                    // Orphan stash — sidecar exists but no merge state on
                    // disk and no unresolved paths. Attempt to pop: a
                    // clean pop restores the user's pre-op state; a
                    // conflicted pop synthesises a StashPop pending merge.
                    let pop_result = self.git.stash_pop(&info.worktree_path, &sc.stash_ref).await;
                    let had_conflicts =
                        matches!(pop_result.as_ref(), Ok(paths) if !paths.is_empty());
                    self.handle_post_stash_pop(&info.session_id, &sc.stash_ref, pop_result);
                    if had_conflicts {
                        restored += 1;
                        // Keep the sidecar for subsequent crash recovery.
                        continue;
                    }
                    // Clean pop — sidecar no longer needed.
                    let _ = super::rebase_on_main::remove_sidecar(
                        &info.worktree_path,
                        &info.session_id,
                    )
                    .await;
                    continue;
                }
                (Some(mut p), Some(sc)) => {
                    // Overlay sidecar data onto the reconstructed merge.
                    p.origin = crate::domains::worktree::types::MergeOrigin::RebaseOnMain;
                    p.auto_stash_ref = Some(sc.stash_ref.clone());
                    p
                }
                (Some(p), None) => p,
            };

            self.state
                .lock()
                .pending_merges
                .insert(info.session_id.clone(), pending.clone());
            restored += 1;

            let strategy_str = match pending.strategy {
                crate::domains::worktree::types::MergeStrategy::Merge => "merge",
                crate::domains::worktree::types::MergeStrategy::Rebase => "rebase",
                crate::domains::worktree::types::MergeStrategy::Squash => "squash",
            };

            let auto_abort_ms = self.config.auto_abort_ms;
            let started_at_ms = pending.started_at_ms.max(0) as u64;
            let auto_abort_at_ms = started_at_ms.saturating_add(auto_abort_ms);
            let origin = pending.origin.as_str().to_string();

            let _ = self.event_store.append(&AppendOptions {
                session_id: &info.session_id,
                event_type: EventType::WorktreePendingMergeDetected,
                payload: json!({
                    "sourceBranch": pending.source_branch,
                    "targetBranch": pending.target_branch,
                    "strategy": strategy_str,
                    "origin": origin.clone(),
                    "startedAtMs": started_at_ms,
                    "autoAbortAtMs": auto_abort_at_ms,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreePendingMergeDetected {
                base: BaseEvent::now(&info.session_id),
                source_branch: pending.source_branch.clone(),
                target_branch: pending.target_branch.clone(),
                strategy: strategy_str.to_string(),
                origin,
                started_at_ms,
                auto_abort_at_ms,
            });

            // Arm the auto-abort timer. The user can cancel it by either
            // completing the merge (which drops the entry from
            // `pending_merges`) or by calling `abort_merge` manually — both
            // paths cause the timer's abort call to be a no-op.
            let coord = self.clone();
            let session_id = info.session_id.clone();
            let now_ms: u64 = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let remaining_ms = auto_abort_at_ms.saturating_sub(now_ms);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(remaining_ms)).await;
                // Bail if the merge has since been resolved or aborted.
                if !coord.state.lock().pending_merges.contains_key(&session_id) {
                    return;
                }
                match coord
                    .abort_merge_with_reason(&session_id, "crash_recovery_timeout")
                    .await
                {
                    Ok(()) => info!(
                        session_id,
                        "auto-aborted pending merge after crash recovery timeout"
                    ),
                    Err(e) => warn!(
                        session_id,
                        error = %e,
                        "auto-abort of pending merge failed"
                    ),
                }
            });
        }

        if restored > 0 {
            info!(restored, "reconstructed pending merges after crash");
        }
        restored
    }
}
