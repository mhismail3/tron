use super::shared::*;
use super::{Deps, RebaseOnMainResult, instrument, map_worktree_error};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── worktree.rebaseOnMain ────────────────────────────────────────────

/// Operation for `worktree.rebaseOnMain` — pull main forward into a
/// session's branch.
pub struct RebaseOnMainOperation;

impl RebaseOnMainOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::rebase_on_main"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        // Parse strategy BEFORE touching the coordinator so "squash" is
        // rejected at the engine transport boundary (plan requirement).
        let strategy = parse_rebase_strategy(opt_string(params.as_ref(), "strategy").as_deref())?;
        let main_branch = opt_string(params.as_ref(), "mainBranch");

        let coord = require_coordinator(deps)?;

        match coord
            .rebase_on_main(&session_id, main_branch.as_deref(), strategy)
            .await
        {
            Ok(RebaseOnMainResult::Success {
                old_base_commit,
                new_base_commit,
                main_commits_incorporated,
                strategy,
                had_auto_stash,
            }) => Ok(json!({
                "type": "success",
                "oldBaseCommit": old_base_commit,
                "newBaseCommit": new_base_commit,
                "mainCommitsIncorporated": main_commits_incorporated as u64,
                "strategy": strategy.as_str(),
                "hadAutoStash": had_auto_stash,
            })),
            Ok(RebaseOnMainResult::Conflicts { count }) => Ok(json!({
                "type": "conflicts",
                "count": count as u64,
                "hint": "call worktree.listConflicts, resolve, then worktree.continueMerge",
            })),
            Ok(RebaseOnMainResult::NoOp { ahead }) => Ok(json!({
                "type": "noOp",
                "ahead": ahead as u64,
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}
