//! Prompt-run worktree resolution.
//!
//! Prompt runs that are configured for isolation must either acquire a session
//! worktree or fail before model execution. They must never silently continue
//! in the original repository because that turns a sandboxed app-session test
//! into a real workspace mutation.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use tracing::{debug, warn};

use crate::domains::session::event_store::EventStore;
use crate::domains::worktree::{AcquireResult, WorktreeCoordinator, WorktreeInfo};

pub(super) struct PromptWorktreeResolution {
    pub(super) worktree_info: Option<WorktreeInfo>,
    pub(super) working_dir: String,
    pub(super) freshly_acquired: bool,
}

pub(super) fn emit_prompt_worktree_failure(
    broadcast: &crate::domains::agent::runner::EventEmitter,
    session_id: &str,
    model: &str,
    message: String,
) {
    warn!(
        session_id = %session_id,
        error = %message,
        "prompt run stopped before model execution because worktree isolation failed"
    );
    let _ = broadcast.emit(crate::shared::events::TronEvent::Error {
        base: crate::shared::events::BaseEvent::now(session_id),
        error: message,
        context: Some("worktree acquisition".into()),
        code: Some("WORKTREE_ACQUISITION_FAILED".into()),
        provider: None,
        category: Some("worktree".into()),
        suggestion: Some(
            "Fix the repository worktree setup or create a passthrough session explicitly.".into(),
        ),
        retryable: Some(false),
        status_code: None,
        error_type: Some("worktree".into()),
        model: Some(model.to_string()),
    });
    let _ = broadcast.emit(crate::shared::events::TronEvent::SessionProcessingChanged {
        base: crate::shared::events::BaseEvent::now(session_id),
        is_processing: false,
    });
}

pub(super) async fn resolve_prompt_worktree(
    is_chat: bool,
    state_worktree_path: Option<&str>,
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: String,
) -> Result<PromptWorktreeResolution, String> {
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
        .await?
    } else {
        acquire_worktree_if_enabled(
            worktree_coordinator,
            event_store,
            session_id,
            &working_dir,
            &mut freshly_acquired,
        )
        .await?
    };

    let working_dir = worktree_info
        .as_ref()
        .map(|info| info.worktree_path.to_string_lossy().to_string())
        .unwrap_or(working_dir);

    Ok(PromptWorktreeResolution {
        worktree_info,
        working_dir,
        freshly_acquired,
    })
}

async fn resolve_recorded_worktree_path(
    wt_path: &str,
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: &str,
    freshly_acquired: &mut bool,
) -> Result<Option<WorktreeInfo>, String> {
    let path_buf = PathBuf::from(wt_path);
    if !path_buf.is_dir() {
        warn!(
            session_id = %session_id,
            stale_path = %path_buf.display(),
            "recorded worktree path no longer exists on disk; re-acquiring"
        );
        if worktree_coordinator.is_none() {
            return Err(
                "recorded worktree path is missing and no worktree coordinator is available"
                    .to_string(),
            );
        }
        return acquire_worktree_if_enabled(
            worktree_coordinator,
            event_store,
            session_id,
            working_dir,
            freshly_acquired,
        )
        .await;
    }

    Ok(worktree_coordinator
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
        }))
}

async fn acquire_worktree_if_enabled(
    worktree_coordinator: &Option<Arc<WorktreeCoordinator>>,
    event_store: &Arc<EventStore>,
    session_id: &str,
    working_dir: &str,
    freshly_acquired: &mut bool,
) -> Result<Option<WorktreeInfo>, String> {
    // None defers to the global IsolationMode setting.
    let use_worktree_override = event_store
        .get_session(session_id)
        .ok()
        .flatten()
        .and_then(|row| row.use_worktree);

    let Some(coordinator) = worktree_coordinator else {
        if use_worktree_override == Some(true) {
            return Err("worktree isolation was requested but no coordinator is available".into());
        }
        return Ok(None);
    };

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
            Ok(Some(info))
        }
        Ok(AcquireResult::Deferred(reason)) => {
            debug!(
                session_id = %session_id,
                reason = ?reason,
                "worktree isolation intentionally deferred for session"
            );
            Ok(None)
        }
        Ok(AcquireResult::Passthrough) => Ok(None),
        Err(error) => Err(format!("worktree acquisition failed: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::{
        ConnectionConfig, EventStore, new_in_memory, run_migrations,
    };
    use crate::domains::worktree::{WorktreeConfig, WorktreeCoordinator};
    use std::sync::Arc;
    use tempfile::tempdir;

    fn make_store() -> Arc<EventStore> {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    async fn run_cmd(dir: &std::path::Path, args: &[&str]) {
        let output = tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(
            output.status.success(),
            "cmd {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    async fn init_repo(dir: &std::path::Path) {
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test\n").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    }

    #[tokio::test]
    async fn prompt_worktree_acquisition_errors_do_not_passthrough_to_repo_root() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join(".worktrees"), "blocks worktree directory").unwrap();

        let store = make_store();
        let created = store
            .create_session_with_worktree_override(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
                Some("project"),
                None,
                Some(true),
            )
            .unwrap();
        let coordinator = Some(Arc::new(WorktreeCoordinator::new(
            WorktreeConfig::default(),
            store.clone(),
        )));

        let result = resolve_prompt_worktree(
            false,
            None,
            &coordinator,
            &store,
            &created.session.id,
            dir.path().to_string_lossy().to_string(),
        )
        .await;

        assert!(
            result.is_err(),
            "worktree acquisition errors must fail closed instead of returning the original repo path"
        );
    }

    #[tokio::test]
    async fn explicit_prompt_worktree_requires_coordinator() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let created = store
            .create_session_with_worktree_override(
                "model",
                &dir.path().to_string_lossy(),
                Some("test"),
                None,
                None,
                Some("project"),
                None,
                Some(true),
            )
            .unwrap();

        let result = resolve_prompt_worktree(
            false,
            None,
            &None,
            &store,
            &created.session.id,
            dir.path().to_string_lossy().to_string(),
        )
        .await;

        assert!(
            result.is_err(),
            "explicit worktree isolation must not downgrade to the repo root when the coordinator is unavailable"
        );
    }

    #[tokio::test]
    async fn stale_recorded_prompt_worktree_requires_reacquire_or_error() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let store = make_store();
        let result = resolve_prompt_worktree(
            false,
            Some(&dir.path().join("missing-worktree").to_string_lossy()),
            &None,
            &store,
            "sess-stale-worktree",
            dir.path().to_string_lossy().to_string(),
        )
        .await;

        assert!(
            result.is_err(),
            "stale recorded worktree paths must not resume in the original repo when no reacquire path exists"
        );
    }
}
