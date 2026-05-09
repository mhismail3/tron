//! Worktree workflow operations.
use super::{ListOperation, require_coordinator, require_session_working_dir, resolve_diff_dir};
use super::{instrument, map_worktree_error};
use crate::domains::worktree::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;

impl ListOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::list"))]
    pub(crate) async fn run(
        &self,
        _params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let coord = require_coordinator(deps)?;

        let active = coord.list_active();
        let worktrees: Vec<Value> = active
            .iter()
            .map(|info| {
                serde_json::json!({
                    "sessionId": info.session_id,
                    "path": info.worktree_path.to_string_lossy(),
                    "branch": info.branch,
                    "baseCommit": info.base_commit,
                    "baseBranch": info.base_branch,
                    "repoRoot": info.repo_root.to_string_lossy(),
                })
            })
            .collect();
        Ok(serde_json::json!({ "worktrees": worktrees }))
    }
}

// ── Acquire ─────────────────────────────────────────────────────────

/// Explicitly acquire a worktree for a session.
pub struct AcquireOperation;

impl AcquireOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::acquire"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        let working_dir = require_session_working_dir(deps, &session_id)?;
        let working_dir = std::path::Path::new(&working_dir);

        match coord.maybe_acquire(&session_id, working_dir).await {
            Ok(crate::domains::worktree::AcquireResult::Acquired(info)) => Ok(serde_json::json!({
                "acquired": true,
                "path": info.worktree_path.to_string_lossy(),
                "branch": info.branch,
                "baseCommit": info.base_commit,
                "baseBranch": info.base_branch,
            })),
            Ok(crate::domains::worktree::AcquireResult::Deferred(reason)) => {
                Ok(serde_json::json!({
                    "acquired": false,
                    "deferred": true,
                    "reason": format!("{reason:?}"),
                }))
            }
            Ok(crate::domains::worktree::AcquireResult::Passthrough) => Ok(serde_json::json!({
                "acquired": false,
                "reason": "not a git repo or isolation disabled",
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── Release ─────────────────────────────────────────────────────────

/// Explicitly release a session's worktree.
pub struct ReleaseOperation;

impl ReleaseOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::release"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        coord
            .release(&session_id)
            .await
            .map_err(|e| map_worktree_error(e))?;

        Ok(serde_json::json!({
            "released": true,
            "sessionId": session_id,
        }))
    }
}

// ── ListSessionBranches ─────────────────────────────────────────────

/// List all session branches (active and preserved) for the repo.
pub struct ListSessionBranchesOperation;

impl ListSessionBranchesOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::list_session_branches"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        let dir = resolve_diff_dir(deps, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let Ok(repo_root_str) = coord.resolve_repo_root(dir_path).await else {
            return Ok(serde_json::json!({ "branches": [] }));
        };

        let repo_root = std::path::Path::new(&repo_root_str);
        match coord.list_session_branches(repo_root).await {
            Ok(branches) => Ok(serde_json::json!({ "branches": branches })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── GetCommittedDiff ────────────────────────────────────────────────

/// Get committed diff for a session (base..HEAD).
pub struct GetCommittedDiffOperation;

impl GetCommittedDiffOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::get_committed_diff"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        match coord.get_committed_diff(&session_id).await {
            Ok(Some(result)) => {
                serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                    message: format!("Serialization failed: {e}"),
                })
            }
            Ok(None) => Ok(serde_json::json!({
                "commits": [],
                "files": [],
                "summary": {
                    "totalFiles": 0,
                    "totalAdditions": 0,
                    "totalDeletions": 0,
                },
                "truncated": false,
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── DeleteBranch ────────────────────────────────────────────────────

/// Delete a single session branch.
pub struct DeleteBranchOperation;
