use super::shared::*;
use super::{Deps, WorktreeError, instrument, map_worktree_error};
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_bool;
use crate::server::shared::params::opt_string;
use crate::server::shared::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── worktree.finalizeSession ─────────────────────────────────────────

/// Operation for `worktree.finalizeSession` — merge session into main and rebranch.
pub struct FinalizeSessionOperation;

impl FinalizeSessionOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::finalize_session"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        // Source branch defaults to the session's current branch.
        let info = coord
            .get_info(&session_id)
            .ok_or_else(|| CapabilityError::NotFound {
                code: crate::server::shared::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            })?;
        let source_branch =
            opt_string(params.as_ref(), "sourceBranch").unwrap_or_else(|| info.branch.clone());
        let target_branch = opt_string(params.as_ref(), "targetBranch")
            .or(info.base_branch.clone())
            .unwrap_or_else(|| "main".into());
        let strategy = parse_strategy(opt_string(params.as_ref(), "strategy").as_deref());
        let new_branch_name = opt_string(params.as_ref(), "newBranchName")
            .unwrap_or_else(|| format!("{}-follow-up", info.branch));
        let preserve_old = opt_bool(params.as_ref(), "preserveOld").unwrap_or(true);
        // `rebranch` defaults to true (the historical behaviour). When the
        // iOS client sets it to false, the worktree stays on its current
        // branch post-merge — no follow-up branch is created.
        let rebranch = opt_bool(params.as_ref(), "rebranch").unwrap_or(true);

        match coord
            .finalize_session(
                &session_id,
                &source_branch,
                &target_branch,
                strategy,
                &new_branch_name,
                preserve_old,
                rebranch,
            )
            .await
        {
            Ok(res) => Ok(json!({
                "mergeCommit": res.merge_commit,
                "newBranch": res.new_branch,
                "newBaseCommit": res.new_base_commit,
                "oldBranchDeleted": res.old_branch_deleted,
                "oldBranchDeleteError": res.old_branch_delete_error,
                "strategy": res.strategy.as_str(),
            })),
            // Conflicts surface as a typed `MergeConflicts(count)` error —
            // map it to a machine-readable response so the caller can
            // transition into the state machine (`startMerge` → resolve →
            // `continueMerge`).
            Err(WorktreeError::MergeConflicts(count)) => Ok(json!({
                "conflicts": true,
                "conflictCount": count,
                "error": format!("merge has conflicts ({} file(s)); resolve first", count),
                "hint": "call worktree.startMerge, resolve, then worktree.continueMerge",
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}
