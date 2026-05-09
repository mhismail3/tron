//! Worktree workflow operations.
use super::{DeleteBranchOperation, require_coordinator, resolve_diff_dir};
use super::{instrument, map_worktree_error};
use crate::domains::worktree::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;

impl DeleteBranchOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::delete_branch"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let branch = require_string_param(params.as_ref(), "branch")?;
        let coord = require_coordinator(deps)?;

        let dir = resolve_diff_dir(deps, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord
            .resolve_repo_root(dir_path)
            .await
            .map_err(|e| map_worktree_error(e))?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.delete_session_branch(repo_root, &branch).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── PruneBranches ───────────────────────────────────────────────────

/// Prune all inactive session branches.
pub struct PruneBranchesOperation;

impl PruneBranchesOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::prune_branches"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        let dir = resolve_diff_dir(deps, &session_id)?;
        let dir_path = std::path::Path::new(&dir);
        let repo_root_str = coord
            .resolve_repo_root(dir_path)
            .await
            .map_err(|e| map_worktree_error(e))?;
        let repo_root = std::path::Path::new(&repo_root_str);

        match coord.prune_session_branches(repo_root).await {
            Ok(result) => serde_json::to_value(&result).map_err(|e| CapabilityError::Internal {
                message: format!("Serialization failed: {e}"),
            }),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}
