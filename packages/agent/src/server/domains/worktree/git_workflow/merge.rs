use super::shared::*;
use super::{Deps, instrument, map_worktree_error};
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_string;
use crate::server::shared::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── worktree.startMerge ──────────────────────────────────────────────

/// Operation for `worktree.startMerge` — begin a merge that keeps conflicts.
pub struct StartMergeOperation;

impl StartMergeOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::start_merge"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let source = require_string_param(params.as_ref(), "sourceBranch")?;
        let target = require_string_param(params.as_ref(), "targetBranch")?;
        let strategy = parse_strategy(opt_string(params.as_ref(), "strategy").as_deref());
        let coord = require_coordinator(deps)?;

        let pending = coord
            .start_merge_keep_conflicts(&session_id, &source, &target, strategy)
            .await
            .map_err(|e| map_worktree_error(e))?;

        // Probe conflicts so the caller gets the file list up front.
        let conflicts = coord.list_conflicts(&session_id).await.unwrap_or_default();
        Ok(json!({
            "pending": {
                "sessionId": pending.session_id,
                "sourceBranch": pending.source_branch,
                "targetBranch": pending.target_branch,
                "strategy": pending.strategy.as_str(),
                "startedAtMs": pending.started_at_ms,
                "crashRecovered": pending.crash_recovered,
            },
            "conflicts": conflicts.iter().map(conflicted_file_json).collect::<Vec<_>>(),
        }))
    }
}
