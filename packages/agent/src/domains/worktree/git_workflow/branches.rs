use super::shared::*;
use super::{Deps, instrument, map_worktree_error};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── git.listLocalBranches ────────────────────────────────────────────

/// Operation for `git.listLocalBranches` — return every local branch in the
/// session's repo (mainline branches first, session/* branches last).
pub struct ListLocalBranchesOperation;

impl ListLocalBranchesOperation {
    #[instrument(skip(self, deps), fields(method = "git::list_local_branches"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;
        let session_dir_hint = session_working_dir(deps, &session_id);
        let branches = coord
            .list_local_branches(&session_id, session_dir_hint.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        // `current` is best-effort: isolated sessions read it from the
        // coordinator's in-memory info, passthrough sessions read it from
        // git HEAD of the session's working dir.
        let current = if let Some(info) = coord.get_info(&session_id) {
            Some(info.branch)
        } else if let Some(ref dir) = session_dir_hint {
            coord
                .passthrough_status(dir)
                .await
                .ok()
                .flatten()
                .map(|s| s.branch)
        } else {
            None
        };
        Ok(json!({
            "branches": branches,
            "current": current,
        }))
    }
}

// ── git.listRemoteBranches ───────────────────────────────────────────

/// Operation for `git.listRemoteBranches` — return every branch published on
/// the given remote (default `origin`). Used by the Merge Changes target
/// picker so unpublished/session branches never appear as merge targets.
pub struct ListRemoteBranchesOperation;

impl ListRemoteBranchesOperation {
    #[instrument(skip(self, deps), fields(method = "git::list_remote_branches"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let remote = opt_string(params.as_ref(), "remote");
        let coord = require_coordinator(deps)?;
        let session_dir_hint = session_working_dir(deps, &session_id);
        let branches = coord
            .list_remote_branches(&session_id, remote.as_deref(), session_dir_hint.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({
            "branches": branches,
            "remote": remote.unwrap_or_else(|| "origin".into()),
        }))
    }
}
