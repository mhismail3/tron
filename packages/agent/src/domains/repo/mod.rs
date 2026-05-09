//! repo domain worker.
//!
//! This module owns canonical function execution for the repo namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

use crate::shared::server::errors;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

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

async fn list_sessions(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let coord = require_coordinator(deps)?;
    let caller_info = coord
        .get_info(&session_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::WORKTREE_NOT_FOUND.into(),
            message: format!("No worktree found for session '{session_id}'"),
        })?;
    let caller_repo = caller_info.repo_root.clone();
    let peers: Vec<_> = coord
        .list_active()
        .into_iter()
        .filter(|info| info.repo_root == caller_repo)
        .collect();
    let coord_ref = coord;
    let futs = peers.into_iter().map(|info| async move {
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
    Ok(json!({ "sessions": futures::future::join_all(futs).await }))
}

async fn get_divergence(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let coord = require_coordinator(deps)?;
    let info = coord
        .get_info(&session_id)
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::WORKTREE_NOT_FOUND.into(),
            message: format!("No worktree found for session '{session_id}'"),
        })?;
    let main_branch = info.base_branch.clone().unwrap_or_else(|| "main".into());
    let main_pair = coord
        .ahead_behind_optional(&info.repo_root, &main_branch, &info.branch)
        .await
        .unwrap_or(None);
    let origin_pair = if coord.has_remote(&info.repo_root, "origin").await {
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
        "hasOrigin": origin_pair.is_some(),
    }))
}
