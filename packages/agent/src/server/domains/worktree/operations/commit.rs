//! Worktree workflow operations.
use super::{CommitOperation, require_coordinator};
use super::{CommitOptions, instrument, map_worktree_error, require_bool};
use crate::server::domains::worktree::Deps;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_bool;
use crate::server::shared::params::opt_string;
use crate::server::shared::params::require_string_param;
use serde_json::Value;

impl CommitOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::commit"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = require_string_param(params.as_ref(), "message")?;
        let coord = require_coordinator(deps)?;

        if coord.get_info(&session_id).is_none() {
            return Err(CapabilityError::NotFound {
                code: crate::server::shared::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            });
        }

        // `stageAll` is contractually required — there is no sane server-side
        // default now that iOS ships with an explicit toggle (I7). A client
        // that omits it is bugged and must be fixed, not silently coerced.
        // `amend` and `signoff` remain opt-in feature flags; the vast
        // majority of callers want them off and sending `false` on every
        // wire would be pure overhead.
        let opts = CommitOptions {
            amend: opt_bool(params.as_ref(), "amend").unwrap_or(false),
            signoff: opt_bool(params.as_ref(), "signoff").unwrap_or(false),
            stage_all: require_bool(params.as_ref(), "stageAll")?,
        };

        match coord.commit(&session_id, &message, opts).await {
            Ok(Some(result)) => {
                // Record worktree.commit event for compaction progress signal detection.
                if let Some(handler) = deps.orchestrator.get_compaction_handler(&session_id) {
                    handler.record_event_type("worktree::commit");
                }
                Ok(serde_json::json!({
                    "commitHash": result.commit_hash,
                    "message": message,
                    "filesChanged": result.files_changed,
                    "insertions": result.insertions,
                    "deletions": result.deletions,
                }))
            }
            Ok(None) => Ok(serde_json::json!({
                "commitHash": null,
                "message": "nothing to commit",
            })),
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── Merge ───────────────────────────────────────────────────────────

/// Merge worktree.
pub struct MergeOperation;

impl MergeOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::merge"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target_branch = opt_string(params.as_ref(), "targetBranch");
        let target_branch = target_branch.as_deref().unwrap_or("main");
        let strategy_str = opt_string(params.as_ref(), "strategy");
        let coord = require_coordinator(deps)?;

        if coord.get_info(&session_id).is_none() {
            return Err(CapabilityError::NotFound {
                code: crate::server::shared::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            });
        }

        let strategy = match strategy_str.as_deref() {
            Some("rebase") => crate::worktree::MergeStrategy::Rebase,
            Some("squash") => crate::worktree::MergeStrategy::Squash,
            _ => crate::worktree::MergeStrategy::Merge,
        };

        match coord.merge(&session_id, target_branch, strategy).await {
            Ok(result) => {
                let conflicts: Option<Vec<String>> = if result.conflicts.is_empty() {
                    None
                } else {
                    Some(result.conflicts)
                };
                Ok(serde_json::json!({
                    "success": result.success,
                    "mergeCommit": result.merge_commit,
                    "conflicts": conflicts,
                }))
            }
            Err(e) => Err(map_worktree_error(e)),
        }
    }
}

// ── List ────────────────────────────────────────────────────────────

/// List worktrees across all sessions.
pub struct ListOperation;
