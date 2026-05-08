//! Prompt-run worktree resolution.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tracing::{debug, warn};

use crate::events::EventStore;
use crate::worktree::{AcquireResult, WorktreeCoordinator, WorktreeInfo};

pub(super) struct PromptWorktreeResolution {
    pub(super) worktree_info: Option<WorktreeInfo>,
    pub(super) working_dir: String,
    pub(super) freshly_acquired: bool,
}

pub(super) async fn resolve_prompt_worktree(
    is_chat: bool,
    state_worktree_path: Option<&str>,
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: String,
) -> PromptWorktreeResolution {
    let mut freshly_acquired = false;
    let worktree_info = if is_chat {
        // INVARIANT: Chat sessions never acquire a worktree. This is a
        // server-enforced rule independent of the global IsolationMode
        // and any per-session `useWorktree` override.
        None
    } else if let Some(wt_path) = state_worktree_path {
        resolve_recorded_worktree_path(
            wt_path,
            worktree_coordinator,
            event_store,
            session_id,
            &working_dir,
            &mut freshly_acquired,
        )
        .await
    } else {
        acquire_worktree_if_enabled(
            worktree_coordinator,
            event_store,
            session_id,
            &working_dir,
            &mut freshly_acquired,
        )
        .await
    };

    let working_dir = worktree_info
        .as_ref()
        .map(|info| info.worktree_path.to_string_lossy().to_string())
        .unwrap_or(working_dir);

    PromptWorktreeResolution {
        worktree_info,
        working_dir,
        freshly_acquired,
    }
}

async fn resolve_recorded_worktree_path(
    wt_path: &str,
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: &str,
    freshly_acquired: &mut bool,
) -> Option<WorktreeInfo> {
    let path_buf = PathBuf::from(wt_path);
    if !path_buf.is_dir() {
        warn!(
            session_id = %session_id,
            stale_path = %path_buf.display(),
            "recorded worktree path no longer exists on disk; re-acquiring"
        );
        return acquire_worktree_if_enabled(
            worktree_coordinator,
            event_store,
            session_id,
            working_dir,
            freshly_acquired,
        )
        .await;
    }

    worktree_coordinator
        .as_ref()
        .and_then(|coordinator| coordinator.get_info(session_id))
        .or_else(|| {
            Some(WorktreeInfo {
                session_id: session_id.to_owned(),
                worktree_path: path_buf,
                branch: String::new(),
                base_commit: String::new(),
                base_branch: None,
                original_working_dir: PathBuf::from(working_dir),
                repo_root: PathBuf::from(working_dir),
            })
        })
}

async fn acquire_worktree_if_enabled(
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: &str,
    freshly_acquired: &mut bool,
) -> Option<WorktreeInfo> {
    let Some(coordinator) = worktree_coordinator else {
        return None;
    };

    // None defers to the global IsolationMode setting.
    let use_worktree_override = event_store
        .get_session(session_id)
        .ok()
        .flatten()
        .and_then(|row| row.use_worktree);

    match coordinator
        .maybe_acquire_with_override(session_id, Path::new(working_dir), use_worktree_override)
        .await
    {
        Ok(AcquireResult::Acquired(info)) => {
            *freshly_acquired = true;
            debug!(
                session_id = %session_id,
                worktree = %info.worktree_path.display(),
                branch = %info.branch,
                "worktree acquired for session"
            );
            Some(info)
        }
        Ok(AcquireResult::Deferred(reason)) => {
            debug!(
                session_id = %session_id,
                reason = ?reason,
                "worktree deferred, using original directory"
            );
            None
        }
        Ok(AcquireResult::Passthrough) => None,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "worktree acquisition failed, using original directory"
            );
            None
        }
    }
}
