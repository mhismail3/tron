use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde_json::json;
use tracing::{debug, info, warn};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::sqlite::repositories::session::ListSessionsOptions;
use crate::events::{AppendOptions, EventType};
use crate::worktree::types::WorktreeInfo;

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
            match crate::worktree::recovery::recover_repo(&repo_root, &active_branches, &self.config, &self.git)
                .await
            {
                Ok(recovered) => total += recovered.len(),
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
            let pending = match crate::worktree::recovery::reconstruct_pending_merge(
                &info, &self.git,
            )
            .await
            {
                Some(p) => p,
                None => continue,
            };

            self.state
                .lock()
                .pending_merges
                .insert(info.session_id.clone(), pending.clone());
            restored += 1;

            let strategy_str = match pending.strategy {
                crate::worktree::types::MergeStrategy::Merge => "merge",
                crate::worktree::types::MergeStrategy::Rebase => "rebase",
                crate::worktree::types::MergeStrategy::Squash => "squash",
            };

            let auto_abort_ms = self.config.auto_abort_ms;
            let started_at_ms = pending.started_at_ms.max(0) as u64;
            let auto_abort_at_ms = started_at_ms.saturating_add(auto_abort_ms);

            let _ = self.event_store.append(&AppendOptions {
                session_id: &info.session_id,
                event_type: EventType::WorktreePendingMergeDetected,
                payload: json!({
                    "sourceBranch": pending.source_branch,
                    "targetBranch": pending.target_branch,
                    "strategy": strategy_str,
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
