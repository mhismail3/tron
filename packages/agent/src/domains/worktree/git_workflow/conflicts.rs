use super::shared::*;
use super::{Deps, instrument, map_worktree_error};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── worktree.listConflicts ───────────────────────────────────────────

/// Operation for `worktree.listConflicts`.
pub struct ListConflictsOperation;

impl ListConflictsOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::list_conflicts"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;
        let conflicts = coord
            .list_conflicts(&session_id)
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({
            "conflicts": conflicts.iter().map(conflicted_file_json).collect::<Vec<_>>(),
        }))
    }
}

// ── worktree.resolveConflict ─────────────────────────────────────────

/// Operation for `worktree.resolveConflict`.
pub struct ResolveConflictOperation;

impl ResolveConflictOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::resolve_conflict"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let path = require_string_param(params.as_ref(), "path")?;
        let resolution_str = require_string_param(params.as_ref(), "resolution")?;
        let resolution = parse_resolution(&resolution_str)?;
        let coord = require_coordinator(deps)?;

        coord
            .resolve_conflict(&session_id, &path, resolution)
            .await
            .map_err(|e| map_worktree_error(e))?;
        let remaining = coord
            .list_conflicts(&session_id)
            .await
            .map(|v| v.len())
            .unwrap_or(0) as u64;
        Ok(json!({
            "resolved": true,
            "remaining": remaining,
        }))
    }
}

// ── worktree.continueMerge ───────────────────────────────────────────

/// Operation for `worktree.continueMerge`.
pub struct ContinueMergeOperation;

impl ContinueMergeOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::continue_merge"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = opt_string(params.as_ref(), "message");
        let coord = require_coordinator(deps)?;
        let sha = coord
            .continue_merge(&session_id, message.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({ "mergeCommit": sha }))
    }
}

// ── worktree.abortMerge ──────────────────────────────────────────────

/// Operation for `worktree.abortMerge`.
pub struct AbortMergeOperation;

impl AbortMergeOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::abort_merge"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let reason = opt_string(params.as_ref(), "reason").unwrap_or_else(|| "user".into());
        let coord = require_coordinator(deps)?;
        coord
            .abort_merge_with_reason(&session_id, &reason)
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({ "aborted": true }))
    }
}
