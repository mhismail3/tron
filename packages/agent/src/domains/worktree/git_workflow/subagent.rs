use super::{Deps, instrument};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── worktree::resolve_conflicts_with_subagent ────────────────────────────

/// Spawns the `conflict-resolver` subagent to drive merge resolution.
///
/// Delegates to [`crate::domains::agent::runner::subagents::conflict_resolver::spawn`],
/// which owns the system prompt, restricted capability allowlist, and
/// auto-abort-on-failure watcher. Returns machine-readable status so
/// iOS can degrade gracefully (e.g. fall back to manual resolution if
/// `spawned == false`).
pub struct ResolveConflictsWithSubagentOperation;

impl ResolveConflictsWithSubagentOperation {
    #[instrument(
        skip(self, deps),
        fields(method = "worktree::resolve_conflicts_with_subagent")
    )]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        // Must have a live coordinator to resolve worktree + merge state.
        let coord = deps
            .worktree_coordinator
            .clone()
            .ok_or(CapabilityError::Internal {
                message: "Worktree isolation is not enabled".into(),
            })?;

        // Subagent manager is optional server-wide. Without it we cannot
        // spawn — return a graceful stub so iOS falls back to manual.
        let Some(manager) = deps.subagent_manager.clone() else {
            return Ok(json!({
                "spawned": false,
                "subagentSessionId": Value::Null,
                "sessionId": session_id,
                "reason": "subagent manager unavailable",
            }));
        };

        let outcome = crate::domains::agent::runner::subagents::conflict_resolver::spawn(
            manager,
            coord,
            &session_id,
        )
        .await;

        Ok(json!({
            "spawned": outcome.spawned,
            "subagentSessionId": outcome.subagent_session_id,
            "sessionId": session_id,
            "reason": outcome.reason,
        }))
    }
}
