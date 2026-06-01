//! repo domain worker.
//!
//! This module owns canonical function execution for the repo namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Repo queries resolve the active isolated worktree first, then fall back to
//! the session's selected git checkout so direct-branch sessions can still show
//! source-control metadata.

use crate::shared::server::errors;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "repo",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

fn require_coordinator(
    deps: &Deps,
) -> Result<&crate::domains::worktree::WorktreeCoordinator, CapabilityError> {
    deps.worktree_coordinator
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

#[derive(Clone)]
struct RepoSessionContext {
    session_id: String,
    branch: String,
    base_branch: Option<String>,
    repo_root: PathBuf,
    isolated: bool,
}

async fn repo_session_context(
    deps: &Deps,
    coord: &crate::domains::worktree::WorktreeCoordinator,
    session_id: &str,
) -> Result<RepoSessionContext, CapabilityError> {
    if let Some(info) = coord.get_info(session_id) {
        return Ok(RepoSessionContext {
            session_id: info.session_id,
            branch: info.branch,
            base_branch: info.base_branch,
            repo_root: info.repo_root,
            isolated: true,
        });
    }

    let session = deps
        .session_manager
        .get_session(session_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("Session lookup failed: {e}"),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let status = coord
        .passthrough_status(std::path::Path::new(&session.working_directory))
        .await
        .map_err(crate::shared::server::error_mapping::map_worktree_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::WORKTREE_NOT_FOUND.into(),
            message: format!("No git checkout found for session '{session_id}'"),
        })?;

    Ok(RepoSessionContext {
        session_id: session_id.to_string(),
        branch: status.branch,
        base_branch: status.base_branch,
        repo_root: PathBuf::from(status.repo_root),
        isolated: false,
    })
}

async fn list_sessions(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let coord = require_coordinator(deps)?;
    let caller = repo_session_context(deps, coord, &session_id).await?;
    let caller_repo = caller.repo_root.clone();
    let active_peers: Vec<_> = coord
        .list_active()
        .into_iter()
        .filter(|info| info.repo_root == caller_repo)
        .collect();
    let coord_ref = coord;
    let futs = active_peers.into_iter().map(|info| async move {
        let has_conflicts = coord_ref
            .list_conflicts(&info.session_id)
            .await
            .map(|files| !files.is_empty())
            .unwrap_or(false);
        let (commit_count, base_behind) = if let Some(ref base_branch) = info.base_branch {
            coord_ref
                .ahead_behind(&info.repo_root, base_branch, &info.branch)
                .await
                .unwrap_or((0, 0))
        } else {
            (0, 0)
        };
        json!({
            "sessionId": info.session_id,
            "branch": info.branch,
            "baseBranch": info.base_branch,
            "repoRoot": info.repo_root.to_string_lossy(),
            "commitCount": commit_count,
            "baseBehind": base_behind,
            "hasConflicts": has_conflicts,
        })
    });
    let mut sessions = futures::future::join_all(futs).await;
    if !caller.isolated {
        sessions.insert(
            0,
            json!({
                "sessionId": caller.session_id,
                "branch": caller.branch,
                "baseBranch": caller.base_branch,
                "repoRoot": caller.repo_root.to_string_lossy(),
                "commitCount": 0,
                "baseBehind": 0,
                "hasConflicts": false,
            }),
        );
    }
    Ok(json!({ "sessions": sessions }))
}

async fn get_divergence(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let coord = require_coordinator(deps)?;
    let info = repo_session_context(deps, coord, &session_id).await?;
    let main_branch = info
        .base_branch
        .clone()
        .unwrap_or_else(|| info.branch.clone());
    let main_pair = coord
        .ahead_behind_optional(&info.repo_root, &main_branch, &info.branch)
        .await
        .unwrap_or(None);
    let has_origin = coord.has_remote(&info.repo_root, "origin").await;
    let should_compare_origin = info.isolated || info.branch == "main" || info.branch == "master";
    let origin_pair = if has_origin && should_compare_origin {
        let remote_ref = format!("origin/{main_branch}");
        coord
            .ahead_behind_optional(&info.repo_root, &remote_ref, &main_branch)
            .await
            .unwrap_or(None)
    } else {
        None
    };
    Ok(json!({
        "aheadMain": main_pair.map(|(ahead, _)| ahead as u64),
        "behindMain": main_pair.map(|(_, behind)| behind as u64),
        "aheadOrigin": origin_pair.map(|(ahead, _)| ahead as u64),
        "behindOrigin": origin_pair.map(|(_, behind)| behind as u64),
        "hasOrigin": has_origin,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
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

    async fn run_cmd(dir: &std::path::Path, args: &[&str]) -> String {
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
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    async fn init_repo(dir: &std::path::Path) {
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    }

    async fn passthrough_deps() -> (tempfile::TempDir, Deps, String, String) {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        let branch = run_cmd(dir.path(), &["git", "branch", "--show-current"]).await;

        let store = make_store();
        let session_manager = Arc::new(SessionManager::new(store.clone()));
        let session_id = session_manager
            .create_session(
                "test-model",
                &dir.path().to_string_lossy(),
                Some("direct branch"),
                None,
            )
            .unwrap();
        let coord = Arc::new(WorktreeCoordinator::new(WorktreeConfig::default(), store));

        (
            dir,
            Deps {
                session_manager,
                worktree_coordinator: Some(coord),
            },
            session_id,
            branch,
        )
    }

    #[tokio::test]
    async fn list_sessions_includes_passthrough_caller() {
        let (_dir, deps, session_id, branch) = passthrough_deps().await;

        let value = list_sessions(&json!({ "sessionId": session_id }), &deps)
            .await
            .unwrap();
        let sessions = value["sessions"].as_array().unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["sessionId"].as_str(), Some(session_id.as_str()));
        assert_eq!(sessions[0]["branch"].as_str(), Some(branch.as_str()));
        assert_eq!(sessions[0]["commitCount"].as_u64(), Some(0));
        assert_eq!(sessions[0]["hasConflicts"].as_bool(), Some(false));
    }

    #[tokio::test]
    async fn get_divergence_resolves_passthrough_checkout() {
        let (_dir, deps, session_id, _branch) = passthrough_deps().await;

        let value = get_divergence(&json!({ "sessionId": session_id }), &deps)
            .await
            .unwrap();
        assert_eq!(value["aheadMain"].as_u64(), Some(0));
        assert_eq!(value["behindMain"].as_u64(), Some(0));
        assert_eq!(value["aheadOrigin"], serde_json::Value::Null);
        assert_eq!(value["behindOrigin"], serde_json::Value::Null);
        assert_eq!(value["hasOrigin"].as_bool(), Some(false));
    }
}
