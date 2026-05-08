use super::shared::*;
use super::{Deps, instrument, map_worktree_error};
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_bool;
use crate::server::shared::params::opt_string;
use crate::server::shared::params::opt_u64;
use crate::server::shared::params::require_string_param;
use serde_json::Value;
use serde_json::json;

// ── git.syncMain ─────────────────────────────────────────────────────

/// Operation for `git.syncMain` — fast-forward local main from its upstream.
pub struct SyncMainOperation;

impl SyncMainOperation {
    #[instrument(skip(self, deps), fields(method = "git::sync_main"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target = opt_string(params.as_ref(), "targetBranch");
        let remote = opt_string(params.as_ref(), "remote").unwrap_or_else(|| "origin".into());
        let timeout_ms = opt_u64(params.as_ref(), "fetchTimeoutMs", 60_000);
        let prune = opt_bool(params.as_ref(), "prune").unwrap_or(false);
        let dry_run = opt_bool(params.as_ref(), "dryRun").unwrap_or(false);
        let coord = require_coordinator(deps)?;

        let session_dir_hint = session_working_dir(deps, &session_id);
        let outcome = coord
            .sync_main(
                &session_id,
                target.as_deref(),
                &remote,
                timeout_ms,
                prune,
                dry_run,
                session_dir_hint.as_deref(),
            )
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(sync_outcome_json(&outcome))
    }
}

// ── git.push ─────────────────────────────────────────────────────────

/// Operation for `git.push` — push a session branch to its remote.
pub struct PushOperation;

impl PushOperation {
    #[instrument(skip(self, deps), fields(method = "git::push"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let branch = opt_string(params.as_ref(), "branch");
        let remote = opt_string(params.as_ref(), "remote").unwrap_or_else(|| "origin".into());
        let force_with_lease = opt_bool(params.as_ref(), "forceWithLease").unwrap_or(false);
        let set_upstream = opt_bool(params.as_ref(), "setUpstream").unwrap_or(true);
        let dry_run = opt_bool(params.as_ref(), "dryRun").unwrap_or(false);
        let override_protected = opt_bool(params.as_ref(), "overrideProtected").unwrap_or(false);

        let protected: Vec<String> = params
            .as_ref()
            .and_then(|p| p.get("protectedBranches"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_else(|| vec!["main".into(), "master".into(), "develop".into()]);

        let coord = require_coordinator(deps)?;
        let session_dir_hint = session_working_dir(deps, &session_id);
        let out = coord
            .push_branch(
                &session_id,
                branch.as_deref(),
                &remote,
                force_with_lease,
                set_upstream,
                dry_run,
                &protected,
                override_protected,
                session_dir_hint.as_deref(),
            )
            .await
            .map_err(|e| map_worktree_error(e))?;

        // `success` is elided — on this wire path a successful push is
        // the only shape that reaches here (failures throw typed errors).
        Ok(json!({
            "branch": out.branch,
            "remote": out.remote,
            "setUpstream": out.set_upstream,
            "dryRun": out.dry_run,
            "stderr": out.stderr,
        }))
    }
}
