//! Coordinator-level `sync_main`: acquires the per-repo lock then
//! delegates to `scm::sync::sync_main`.
//!
//! The lock guarantees no other session's `sync_main` or
//! `finalize_session` is running against the same repo concurrently.
//!
//! On a successful fast-forward emits:
//!   - `WorktreeMainSynced` — per-session result.
//!   - `RepoMainAdvanced` — repo-wide broadcast so other sessions can
//!     refresh their divergence chips.

use std::path::{Path, PathBuf};

use serde_json::json;
use tracing::debug;

use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::sync::{self as scm_sync, resolve_default_branch};
use crate::domains::worktree::types::SyncOutcome;
use crate::shared::events::{BaseEvent, TronEvent};

use super::WorktreeCoordinator;
use super::repo_lock::LockedOp;

impl WorktreeCoordinator {
    /// Sync a session's repo-level `main` from its upstream.
    ///
    /// `main_branch` is auto-detected from `init.defaultBranch` + the
    /// `main`/`master` ref probe if `None`.
    ///
    /// `fetch_timeout_ms` is plumbed through to the network fetch so the
    /// UI's cancel timeout is respected. `prune` adds `--prune` to the fetch
    /// so stale remote-tracking branches are cleaned up; `dry_run` runs the
    /// fetch but skips the fast-forward and returns a `DryRunPreview`.
    pub async fn sync_main(
        &self,
        session_id: &str,
        main_branch: Option<&str>,
        remote: &str,
        fetch_timeout_ms: u64,
        prune: bool,
        dry_run: bool,
        working_dir: Option<&Path>,
    ) -> Result<SyncOutcome> {
        let repo_root = self.repo_root_or_cwd(session_id, working_dir).await?;
        let _guard = self
            .acquire_repo_lock(&repo_root, session_id, LockedOp::SyncMain)
            .await;

        let outcome = scm_sync::sync_main(
            &repo_root,
            main_branch,
            remote,
            &self.git,
            fetch_timeout_ms,
            prune,
            dry_run,
        )
        .await?;

        if let SyncOutcome::FastForwarded {
            old_head,
            new_head,
            advanced_by,
        } = &outcome
        {
            // Echo whatever branch actually got fast-forwarded. When the
            // caller didn't specify one, re-run the same detection
            // `scm::sync` used so event consumers see the real branch
            // (e.g. `trunk`/`master`) instead of a hardcoded `main`.
            let resolved_main = match main_branch {
                Some(m) => m.to_string(),
                None => resolve_default_branch(&self.git, &repo_root)
                    .await
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| "main".to_string()),
            };
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeMainSynced,
                payload: json!({
                    "mainBranch": resolved_main,
                    "oldHead": old_head,
                    "newHead": new_head,
                    "advancedBy": *advanced_by as u64,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreeMainSynced {
                base: BaseEvent::now(session_id),
                main_branch: resolved_main.clone(),
                old_head: old_head.clone(),
                new_head: new_head.clone(),
                advanced_by: *advanced_by as u64,
            });
            // Repo-wide broadcast so OTHER sessions refresh.
            self.broadcast(TronEvent::RepoMainAdvanced {
                base: BaseEvent::now(session_id),
                repo_root: repo_root.to_string_lossy().to_string(),
                old_head: old_head.clone(),
                new_head: new_head.clone(),
                source_session_id: session_id.to_string(),
                cause: "sync".into(),
            });
            debug!(
                session_id,
                %old_head,
                %new_head,
                advanced_by,
                "main synced, broadcast sent"
            );
        }

        Ok(outcome)
    }

    /// Resolve a repo root for `session_id`, using `working_dir`
    /// when the session has no isolated worktree (passthrough case: the
    /// session runs directly on the repo's working dir, e.g. a fresh
    /// session on `main` or a post-finalize session that never rebranched).
    ///
    /// All git-workflow capability calls that previously required an active
    /// `WorktreeInfo` now call this so they work for on-main sessions too.
    pub(super) async fn repo_root_or_cwd(
        &self,
        session_id: &str,
        working_dir: Option<&Path>,
    ) -> Result<PathBuf> {
        if let Some(info) = self.state.lock().active_info(session_id) {
            return Ok(info.repo_root);
        }
        if let Some(dir) = working_dir
            && self.git.is_git_repo(dir).await
            && let Ok(root) = self.git.repo_root(dir).await
        {
            return Ok(PathBuf::from(root));
        }
        Err(WorktreeError::NotFound {
            session_id: session_id.to_string(),
        })
    }
}
