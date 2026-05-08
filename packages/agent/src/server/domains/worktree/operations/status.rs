//! Worktree workflow operations.
use super::{GetStatusOperation, require_coordinator, require_session_working_dir};
use super::{instrument, map_worktree_error};
use crate::server::domains::worktree::Deps;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::require_string_param;
use serde_json::Value;

impl GetStatusOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::get_status"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(deps)?;

        // Try the coordinator's tracked worktree first (isolated mode).
        let status = match coord.get_status(&session_id).await {
            Ok(Some(s)) => Some(s),
            Ok(None) => {
                // Passthrough: the session never acquired an isolated
                // worktree (fresh session on `main`, or post-finalize
                // without rebranch). Probe the session's own working
                // directory so the UI still gets a status header.
                let Ok(working_dir) = require_session_working_dir(deps, &session_id) else {
                    return Ok(serde_json::json!({
                        "hasWorktree": false,
                        "worktree": null,
                    }));
                };
                let path = std::path::Path::new(&working_dir);
                coord
                    .passthrough_status(path)
                    .await
                    .map_err(|e| map_worktree_error(e))?
            }
            Err(e) => {
                return Err(map_worktree_error(e));
            }
        };

        match status {
            Some(status) => Ok(serde_json::json!({
                "hasWorktree": true,
                "worktree": {
                    "isolated": status.isolated,
                    "path": status.path,
                    "branch": status.branch,
                    "baseCommit": status.base_commit,
                    "baseBranch": status.base_branch,
                    "repoRoot": status.repo_root,
                    "hasUncommittedChanges": status.has_uncommitted_changes,
                    "commitCount": status.commit_count,
                    "isMerged": status.is_merged,
                },
            })),
            None => Ok(serde_json::json!({
                "hasWorktree": false,
                "worktree": null,
            })),
        }
    }
}

// ── IsGitRepo ───────────────────────────────────────────────────────

/// Quick check: is the given absolute path a git repository?
/// Used by the iOS new-session sheet to decide whether to surface the
/// per-session worktree-isolation toggle.
pub struct IsGitRepoOperation;

impl IsGitRepoOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::is_git_repo"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let path = require_string_param(params.as_ref(), "path")?;
        let coord = require_coordinator(deps)?;
        let is_git = coord.is_git_repo(std::path::Path::new(&path)).await;
        Ok(serde_json::json!({ "isGitRepo": is_git }))
    }
}

// ── Commit ──────────────────────────────────────────────────────────

/// Commit worktree changes.
pub struct CommitOperation;
