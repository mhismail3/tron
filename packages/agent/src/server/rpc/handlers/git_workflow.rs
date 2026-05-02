//! Phase 5 — RPC handlers for the git workflow suite.
//!
//! Thin wrappers around the coordinator's Phase 3 operations:
//! - `git.syncMain`, `git.push`, `git.listLocalBranches`
//! - `worktree.finalizeSession`
//! - `worktree.startMerge`, `worktree.listConflicts`,
//!   `worktree.resolveConflict`, `worktree.continueMerge`,
//!   `worktree.abortMerge`, `worktree.resolveConflictsWithSubagent`
//! - `repo.listSessions`, `repo.getDivergence`
//!
//! Handler implementations intentionally keep business logic minimal:
//! param extraction → coordinator call → JSON response. Event emission
//! (`WorktreeMainSynced`, `RepoMainAdvanced`, lock acquire/release, …) is
//! owned by the coordinator layer so it fires for every caller (tool,
//! RPC, subagent).
//!
//! Error mapping: every coordinator error is routed through
//! `super::map_worktree_error`, which classifies `WorktreeError`
//! variants into typed RPC error codes (`PROTECTED_BRANCH`,
//! `NON_FAST_FORWARD`, `NO_REMOTE`, `GIT_AUTH_FAILED`, …). No handler
//! should produce `RpcError::Internal` for a predictable git failure —
//! use the helper instead.

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{
    map_worktree_error, opt_bool, opt_string, opt_u64, require_string_param,
};
use crate::server::rpc::registry::MethodHandler;
use crate::worktree::types::{
    ConflictResolution, MergeStrategy, RebaseOnMainResult, SyncBlockReason, SyncOutcome,
};
use crate::worktree::{ConflictedFile, WorktreeCoordinator, WorktreeError};
use std::path::PathBuf;

// ── Helpers ──────────────────────────────────────────────────────────

fn require_coordinator(ctx: &RpcContext) -> Result<&WorktreeCoordinator, RpcError> {
    ctx.worktree_coordinator
        .as_deref()
        .ok_or_else(|| RpcError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

/// Look up the session's original working directory so the coordinator
/// can fall back to it when the session has no isolated worktree
/// (passthrough mode — session on `main`, or post-finalize with no
/// rebranch). Returns `None` when the session isn't registered, which
/// is propagated as a normal "not found" error by the coordinator.
fn session_working_dir(ctx: &RpcContext, session_id: &str) -> Option<PathBuf> {
    ctx.session_manager
        .get_session(session_id)
        .ok()
        .flatten()
        .map(|s| PathBuf::from(s.working_directory))
}

fn parse_strategy(s: Option<&str>) -> MergeStrategy {
    match s {
        Some("rebase") => MergeStrategy::Rebase,
        Some("squash") => MergeStrategy::Squash,
        _ => MergeStrategy::Merge,
    }
}

/// Strategy parser for `worktree.rebaseOnMain` — accepts only `"rebase"`
/// (default) or `"merge"`. `"squash"` and unknown values error with
/// `INVALID_PARAMS` so callers find out at RPC boundary rather than
/// deep in the coordinator.
fn parse_rebase_strategy(s: Option<&str>) -> Result<MergeStrategy, RpcError> {
    match s {
        None | Some("rebase") => Ok(MergeStrategy::Rebase),
        Some("merge") => Ok(MergeStrategy::Merge),
        Some("squash") => Err(RpcError::InvalidParams {
            message: "rebaseOnMain does not accept 'squash'".into(),
        }),
        Some(other) => Err(RpcError::InvalidParams {
            message: format!("strategy must be 'rebase' or 'merge'; got '{other}'"),
        }),
    }
}

fn parse_resolution(s: &str) -> Result<ConflictResolution, RpcError> {
    match s {
        "ours" => Ok(ConflictResolution::Ours),
        "theirs" => Ok(ConflictResolution::Theirs),
        "markResolved" | "mark_resolved" | "manual" => Ok(ConflictResolution::MarkResolved),
        other => Err(RpcError::InvalidParams {
            message: format!(
                "resolution must be one of 'ours' | 'theirs' | 'markResolved'; got '{other}'"
            ),
        }),
    }
}

fn conflicted_file_json(f: &ConflictedFile) -> Value {
    // `ours` / `theirs` / `base` may be arbitrary bytes — expose as base64
    // so the iOS client can decide whether to decode as UTF-8 or render
    // as a binary summary.
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let b64 = |b: &Option<Vec<u8>>| b.as_ref().map(|v| B64.encode(v));
    json!({
        "path": f.path,
        "isBinary": f.is_binary,
        "kind": match f.kind {
            crate::worktree::types::ConflictKind::BothModified => "both_modified",
            crate::worktree::types::ConflictKind::BothAdded => "both_added",
            crate::worktree::types::ConflictKind::DeletedByUs => "deleted_by_us",
            crate::worktree::types::ConflictKind::DeletedByThem => "deleted_by_them",
            crate::worktree::types::ConflictKind::Rename => "rename",
            crate::worktree::types::ConflictKind::Other => "other",
        },
        "base": b64(&f.base),
        "ours": b64(&f.ours),
        "theirs": b64(&f.theirs),
    })
}

fn sync_outcome_json(o: &SyncOutcome) -> Value {
    match o {
        SyncOutcome::UpToDate { head } => json!({
            "outcome": "upToDate",
            "head": head,
        }),
        SyncOutcome::FastForwarded {
            old_head,
            new_head,
            advanced_by,
        } => json!({
            "outcome": "fastForwarded",
            "oldHead": old_head,
            "newHead": new_head,
            "advancedBy": *advanced_by as u64,
        }),
        SyncOutcome::DryRunPreview {
            head,
            remote_head,
            would_advance_by,
        } => json!({
            "outcome": "dryRunPreview",
            "head": head,
            "remoteHead": remote_head,
            "wouldAdvanceBy": *would_advance_by as u64,
        }),
        SyncOutcome::Blocked(reason) => {
            let (kind, extras) = match reason {
                SyncBlockReason::NoRemote => ("noRemote", json!({})),
                SyncBlockReason::DirtyWorkingTree => ("dirtyWorkingTree", json!({})),
                SyncBlockReason::LocalAhead { ahead } => {
                    ("localAhead", json!({ "ahead": *ahead as u64 }))
                }
                SyncBlockReason::Diverged { ahead, behind } => (
                    "diverged",
                    json!({ "ahead": *ahead as u64, "behind": *behind as u64 }),
                ),
                SyncBlockReason::EmptyRepository => ("emptyRepository", json!({})),
                SyncBlockReason::DetachedHead => ("detachedHead", json!({})),
                SyncBlockReason::NoDefaultBranch => ("noDefaultBranch", json!({})),
                SyncBlockReason::NotOnDefaultBranch { current, expected } => (
                    "notOnDefaultBranch",
                    json!({ "current": current, "expected": expected }),
                ),
                SyncBlockReason::RemoteError(m) => ("remoteError", json!({ "message": m })),
            };
            let mut out = json!({ "outcome": "blocked", "reason": kind });
            if let (Some(o), Some(e)) = (out.as_object_mut(), extras.as_object()) {
                for (k, v) in e {
                    let _ = o.insert(k.clone(), v.clone());
                }
            }
            out
        }
    }
}

// ── git.syncMain ─────────────────────────────────────────────────────

/// Handler for `git.syncMain` — fast-forward local main from its upstream.
pub struct SyncMainHandler;

#[async_trait]
impl MethodHandler for SyncMainHandler {
    #[instrument(skip(self, ctx), fields(method = "git.syncMain"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let target = opt_string(params.as_ref(), "targetBranch");
        let remote = opt_string(params.as_ref(), "remote").unwrap_or_else(|| "origin".into());
        let timeout_ms = opt_u64(params.as_ref(), "fetchTimeoutMs", 60_000);
        let prune = opt_bool(params.as_ref(), "prune").unwrap_or(false);
        let dry_run = opt_bool(params.as_ref(), "dryRun").unwrap_or(false);
        let coord = require_coordinator(ctx)?;

        let fallback = session_working_dir(ctx, &session_id);
        let outcome = coord
            .sync_main(
                &session_id,
                target.as_deref(),
                &remote,
                timeout_ms,
                prune,
                dry_run,
                fallback.as_deref(),
            )
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(sync_outcome_json(&outcome))
    }
}

// ── git.push ─────────────────────────────────────────────────────────

/// Handler for `git.push` — push a session branch to its remote.
pub struct PushHandler;

#[async_trait]
impl MethodHandler for PushHandler {
    #[instrument(skip(self, ctx), fields(method = "git.push"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
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

        let coord = require_coordinator(ctx)?;
        let fallback = session_working_dir(ctx, &session_id);
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
                fallback.as_deref(),
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

// ── git.listLocalBranches ────────────────────────────────────────────

/// Handler for `git.listLocalBranches` — return every local branch in the
/// session's repo (mainline branches first, session/* branches last).
pub struct ListLocalBranchesHandler;

#[async_trait]
impl MethodHandler for ListLocalBranchesHandler {
    #[instrument(skip(self, ctx), fields(method = "git.listLocalBranches"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;
        let fallback = session_working_dir(ctx, &session_id);
        let branches = coord
            .list_local_branches(&session_id, fallback.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        // `current` is best-effort: isolated sessions read it from the
        // coordinator's in-memory info, passthrough sessions read it from
        // git HEAD of the session's working dir.
        let current = if let Some(info) = coord.get_info(&session_id) {
            Some(info.branch)
        } else if let Some(ref dir) = fallback {
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

/// Handler for `git.listRemoteBranches` — return every branch published on
/// the given remote (default `origin`). Used by the Merge Changes target
/// picker so unpublished/session branches never appear as merge targets.
pub struct ListRemoteBranchesHandler;

#[async_trait]
impl MethodHandler for ListRemoteBranchesHandler {
    #[instrument(skip(self, ctx), fields(method = "git.listRemoteBranches"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let remote = opt_string(params.as_ref(), "remote");
        let coord = require_coordinator(ctx)?;
        let fallback = session_working_dir(ctx, &session_id);
        let branches = coord
            .list_remote_branches(&session_id, remote.as_deref(), fallback.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({
            "branches": branches,
            "remote": remote.unwrap_or_else(|| "origin".into()),
        }))
    }
}

// ── worktree.finalizeSession ─────────────────────────────────────────

/// Handler for `worktree.finalizeSession` — merge session into main and rebranch.
pub struct FinalizeSessionHandler;

#[async_trait]
impl MethodHandler for FinalizeSessionHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.finalizeSession"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        // Source branch defaults to the session's current branch.
        let info = coord
            .get_info(&session_id)
            .ok_or_else(|| RpcError::NotFound {
                code: crate::server::rpc::errors::WORKTREE_NOT_FOUND.into(),
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

// ── worktree.rebaseOnMain ────────────────────────────────────────────

/// Handler for `worktree.rebaseOnMain` — pull main forward into a
/// session's branch.
pub struct RebaseOnMainHandler;

#[async_trait]
impl MethodHandler for RebaseOnMainHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.rebaseOnMain"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        // Parse strategy BEFORE touching the coordinator so "squash" is
        // rejected at the RPC boundary (plan requirement).
        let strategy = parse_rebase_strategy(opt_string(params.as_ref(), "strategy").as_deref())?;
        let main_branch = opt_string(params.as_ref(), "mainBranch");

        let coord = require_coordinator(ctx)?;

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

// ── worktree.startMerge ──────────────────────────────────────────────

/// Handler for `worktree.startMerge` — begin a merge that keeps conflicts.
pub struct StartMergeHandler;

#[async_trait]
impl MethodHandler for StartMergeHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.startMerge"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let source = require_string_param(params.as_ref(), "sourceBranch")?;
        let target = require_string_param(params.as_ref(), "targetBranch")?;
        let strategy = parse_strategy(opt_string(params.as_ref(), "strategy").as_deref());
        let coord = require_coordinator(ctx)?;

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

// ── worktree.listConflicts ───────────────────────────────────────────

/// Handler for `worktree.listConflicts`.
pub struct ListConflictsHandler;

#[async_trait]
impl MethodHandler for ListConflictsHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.listConflicts"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;
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

/// Handler for `worktree.resolveConflict`.
pub struct ResolveConflictHandler;

#[async_trait]
impl MethodHandler for ResolveConflictHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.resolveConflict"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let path = require_string_param(params.as_ref(), "path")?;
        let resolution_str = require_string_param(params.as_ref(), "resolution")?;
        let resolution = parse_resolution(&resolution_str)?;
        let coord = require_coordinator(ctx)?;

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

/// Handler for `worktree.continueMerge`.
pub struct ContinueMergeHandler;

#[async_trait]
impl MethodHandler for ContinueMergeHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.continueMerge"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let message = opt_string(params.as_ref(), "message");
        let coord = require_coordinator(ctx)?;
        let sha = coord
            .continue_merge(&session_id, message.as_deref())
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({ "mergeCommit": sha }))
    }
}

// ── worktree.abortMerge ──────────────────────────────────────────────

/// Handler for `worktree.abortMerge`.
pub struct AbortMergeHandler;

#[async_trait]
impl MethodHandler for AbortMergeHandler {
    #[instrument(skip(self, ctx), fields(method = "worktree.abortMerge"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let reason = opt_string(params.as_ref(), "reason").unwrap_or_else(|| "user".into());
        let coord = require_coordinator(ctx)?;
        coord
            .abort_merge_with_reason(&session_id, &reason)
            .await
            .map_err(|e| map_worktree_error(e))?;
        Ok(json!({ "aborted": true }))
    }
}

// ── worktree.resolveConflictsWithSubagent ────────────────────────────

/// Spawns the `conflict-resolver` subagent to drive merge resolution.
///
/// Delegates to [`crate::runtime::subagents::conflict_resolver::spawn`],
/// which owns the system prompt, restricted tool allowlist, and
/// auto-abort-on-failure watcher. Returns machine-readable status so
/// iOS can degrade gracefully (e.g. fall back to manual resolution if
/// `spawned == false`).
pub struct ResolveConflictsWithSubagentHandler;

#[async_trait]
impl MethodHandler for ResolveConflictsWithSubagentHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "worktree.resolveConflictsWithSubagent")
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        // Must have a live coordinator to resolve worktree + merge state.
        let coord = ctx.worktree_coordinator.clone().ok_or(RpcError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })?;

        // Subagent manager is optional server-wide. Without it we cannot
        // spawn — return a graceful stub so iOS falls back to manual.
        let Some(manager) = ctx.subagent_manager.clone() else {
            return Ok(json!({
                "spawned": false,
                "subagentSessionId": Value::Null,
                "sessionId": session_id,
                "reason": "subagent manager unavailable",
            }));
        };

        let outcome =
            crate::runtime::subagents::conflict_resolver::spawn(manager, coord, &session_id).await;

        Ok(json!({
            "spawned": outcome.spawned,
            "subagentSessionId": outcome.subagent_session_id,
            "sessionId": session_id,
            "reason": outcome.reason,
        }))
    }
}

// ── repo.listSessions ────────────────────────────────────────────────

/// Handler for `repo.listSessions` — sibling sessions sharing the repo.
pub struct ListRepoSessionsHandler;

#[async_trait]
impl MethodHandler for ListRepoSessionsHandler {
    #[instrument(skip(self, ctx), fields(method = "repo.listSessions"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let caller_info = coord
            .get_info(&session_id)
            .ok_or_else(|| RpcError::NotFound {
                code: crate::server::rpc::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            })?;
        let caller_repo = caller_info.repo_root.clone();

        // Filter to peers sharing the caller's repo, then fan-out the
        // per-session queries concurrently. With N peers in the same repo
        // each doing 2–3 `git` subprocess calls, sequential iteration was
        // observably slow when opening the Repo Sessions sheet; `join_all`
        // reduces wall time to ~max(query_time) instead of the sum.
        let peers: Vec<_> = coord
            .list_active()
            .into_iter()
            .filter(|info| info.repo_root == caller_repo)
            .collect();

        let coord_ref = &coord;
        let futs = peers.into_iter().map(|info| async move {
            let has_conflicts = coord_ref
                .list_conflicts(&info.session_id)
                .await
                .map(|v| !v.is_empty())
                .unwrap_or(false);
            let (commit_count, base_behind) = if let Some(ref base_branch) = info.base_branch {
                coord_ref
                    .ahead_behind(&info.repo_root, base_branch, &info.branch)
                    .await
                    .unwrap_or((0, 0))
            } else {
                (0, 0)
            };
            json!({
                "sessionId": info.session_id,
                "branch": info.branch,
                "baseBranch": info.base_branch,
                "repoRoot": info.repo_root.to_string_lossy(),
                "commitCount": commit_count,
                "baseBehind": base_behind,
                "hasConflicts": has_conflicts,
            })
        });
        let out = futures::future::join_all(futs).await;

        Ok(json!({ "sessions": out }))
    }
}

// ── repo.getDivergence ───────────────────────────────────────────────

/// Handler for `repo.getDivergence` — ahead/behind vs main and origin.
pub struct GetDivergenceHandler;

#[async_trait]
impl MethodHandler for GetDivergenceHandler {
    #[instrument(skip(self, ctx), fields(method = "repo.getDivergence"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let coord = require_coordinator(ctx)?;

        let info = coord
            .get_info(&session_id)
            .ok_or_else(|| RpcError::NotFound {
                code: crate::server::rpc::errors::WORKTREE_NOT_FOUND.into(),
                message: format!("No worktree found for session '{session_id}'"),
            })?;
        let main_branch = info.base_branch.clone().unwrap_or_else(|| "main".into());

        // Session-vs-main: null if `main_branch` itself doesn't resolve
        // (e.g. detached, renamed default, fresh empty repo).
        let main_pair = coord
            .ahead_behind_optional(&info.repo_root, &main_branch, &info.branch)
            .await
            .unwrap_or(None);

        // Origin-vs-main: null if no `origin` remote is configured or the
        // remote ref hasn't been fetched. Distinguishes "no remote" from
        // "synced at 0/0" so the UI can fade/hide these chips instead of
        // silently lying about divergence.
        let origin_pair = if coord.has_remote(&info.repo_root, "origin").await {
            let remote_ref = format!("origin/{}", main_branch);
            coord
                .ahead_behind_optional(&info.repo_root, &remote_ref, &main_branch)
                .await
                .unwrap_or(None)
        } else {
            None
        };

        Ok(json!({
            "aheadMain": main_pair.map(|(a, _)| a as u64),
            "behindMain": main_pair.map(|(_, b)| b as u64),
            "aheadOrigin": origin_pair.map(|(a, _)| a as u64),
            "behindOrigin": origin_pair.map(|(_, b)| b as u64),
            "hasOrigin": origin_pair.is_some(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn sync_main_requires_coordinator() {
        let ctx = make_test_context();
        let err = SyncMainHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn push_requires_coordinator() {
        let ctx = make_test_context();
        let err = PushHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn finalize_requires_coordinator() {
        let ctx = make_test_context();
        let err = FinalizeSessionHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    // ── Phase A — rebase_on_main parser & handler guards ───────────

    #[tokio::test]
    async fn rebase_on_main_requires_coordinator() {
        let ctx = make_test_context();
        let err = RebaseOnMainHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn rebase_on_main_missing_session_id() {
        let ctx = make_test_context();
        let err = RebaseOnMainHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn rebase_on_main_rejects_squash_strategy() {
        let ctx = make_test_context();
        let err = RebaseOnMainHandler
            .handle(Some(json!({"sessionId": "s1", "strategy": "squash"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("squash"));
    }

    #[tokio::test]
    async fn rebase_on_main_rejects_unknown_strategy() {
        let ctx = make_test_context();
        let err = RebaseOnMainHandler
            .handle(
                Some(json!({"sessionId": "s1", "strategy": "wizardry"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[test]
    fn parse_strategy_defaults_to_rebase_when_absent() {
        assert_eq!(parse_rebase_strategy(None).unwrap(), MergeStrategy::Rebase);
        assert_eq!(
            parse_rebase_strategy(Some("rebase")).unwrap(),
            MergeStrategy::Rebase
        );
        assert_eq!(
            parse_rebase_strategy(Some("merge")).unwrap(),
            MergeStrategy::Merge
        );
        assert!(parse_rebase_strategy(Some("squash")).is_err());
        assert!(parse_rebase_strategy(Some("foo")).is_err());
    }

    #[tokio::test]
    async fn start_merge_requires_branches() {
        let ctx = make_test_context();
        let err = StartMergeHandler
            .handle(Some(json!({"sessionId": "s1", "sourceBranch": "x"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_conflicts_requires_coordinator() {
        let ctx = make_test_context();
        let err = ListConflictsHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn resolve_conflict_rejects_bad_resolution() {
        let ctx = make_test_context();
        let err = ResolveConflictHandler
            .handle(
                Some(json!({
                    "sessionId": "s1",
                    "path": "f.txt",
                    "resolution": "bogus",
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn continue_merge_requires_coordinator() {
        let ctx = make_test_context();
        let err = ContinueMergeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn abort_merge_requires_coordinator() {
        let ctx = make_test_context();
        let err = AbortMergeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn subagent_handler_returns_stub() {
        let ctx = make_test_context();
        // Without coordinator it errors; we just validate session id
        // validation runs first.
        let err = ResolveConflictsWithSubagentHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_repo_sessions_requires_coordinator() {
        let ctx = make_test_context();
        let err = ListRepoSessionsHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[tokio::test]
    async fn get_divergence_requires_coordinator() {
        let ctx = make_test_context();
        let err = GetDivergenceHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("not enabled"));
    }

    #[test]
    fn parse_resolution_accepts_three_variants() {
        assert_eq!(parse_resolution("ours").unwrap(), ConflictResolution::Ours);
        assert_eq!(
            parse_resolution("theirs").unwrap(),
            ConflictResolution::Theirs
        );
        assert_eq!(
            parse_resolution("markResolved").unwrap(),
            ConflictResolution::MarkResolved
        );
        assert!(parse_resolution("???").is_err());
    }

    // ── PushHandler integration tests for typed-error mapping ─────
    //
    // These prove the handler routes through `map_worktree_error`
    // rather than swallowing WorktreeError variants into
    // INTERNAL_ERROR (the bug that shipped as a user-visible
    // "internal error" popup). Every assertion here is a regression
    // guard: if a future refactor re-introduces the generic
    // `.map_err(|e| RpcError::Internal{...})?` pattern, these fail.

    async fn push_test_context() -> (
        tempfile::TempDir,
        crate::server::rpc::context::RpcContext,
        String,
    ) {
        use crate::events::EventStore;
        use crate::runtime::orchestrator::orchestrator::Orchestrator;
        use crate::runtime::orchestrator::session_manager::SessionManager;
        use crate::server::rpc::context::RpcContext;
        use crate::server::rpc::session_context::ContextArtifactsService;
        use crate::skills::registry::SkillRegistry;
        use crate::worktree::types::AcquireResult;
        use crate::worktree::{WorktreeConfig, WorktreeCoordinator};
        use std::sync::Arc;

        let tmp = tempfile::TempDir::new().unwrap();
        let dir = tmp.path().to_str().unwrap().to_string();
        // Seed a real repo (no origin — push will hit NoRemoteConfigured
        // when we pick a non-protected branch name).
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .output()
                .unwrap();
        };
        run(&["init", &dir]);
        run(&["-C", &dir, "config", "user.email", "t@t.com"]);
        run(&["-C", &dir, "config", "user.name", "T"]);
        run(&["-C", &dir, "config", "commit.gpgsign", "false"]);
        run(&["-C", &dir, "symbolic-ref", "HEAD", "refs/heads/main"]);
        std::fs::write(tmp.path().join("seed.txt"), "seed").unwrap();
        run(&["-C", &dir, "add", "-A"]);
        run(&["-C", &dir, "commit", "-m", "init"]);

        let pool =
            crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store.clone()));
        let orch = Arc::new(Orchestrator::new(mgr.clone()));
        let coord = Arc::new(WorktreeCoordinator::new(
            WorktreeConfig::default(),
            store.clone(),
        ));

        let sid = mgr
            .create_session("m", &dir, Some("push-test"), None)
            .unwrap();
        // Acquire a session worktree so active_info resolves.
        match coord.maybe_acquire(&sid, tmp.path()).await.unwrap() {
            AcquireResult::Acquired(_) => {}
            other => panic!("expected Acquired, got {other:?}"),
        };
        let home = crate::server::rpc::handlers::test_helpers::unique_tron_home();
        let settings_path =
            crate::server::rpc::handlers::test_helpers::test_user_profile_path(&home);
        let profile_runtime =
            crate::server::rpc::handlers::test_helpers::test_profile_runtime(&home);
        let auth_path = crate::server::rpc::handlers::test_helpers::test_auth_path(&home);

        let ctx = RpcContext {
            orchestrator: orch,
            session_manager: mgr,
            event_store: store,
            engine_host: crate::engine::EngineHostHandle::new_in_memory().unwrap(),
            skill_registry: Arc::new(parking_lot::RwLock::new(SkillRegistry::new())),
            memory_registry: Arc::new(parking_lot::Mutex::new(
                crate::runtime::memory::MemoryRegistry::new(),
            )),
            settings_path,
            profile_runtime,
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            codex_app_server: None,
            worktree_coordinator: Some(coord.clone()),
            device_request_broker: None,
            context_artifacts: Arc::new(ContextArtifactsService::new()),
            auth_path,
            broadcast_manager: None,
            oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
            mcp_router: None,
            display_stream_registry: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            hook_abort_tracker: Arc::new(
                crate::runtime::hooks::abort_tracker::HookAbortTracker::new(),
            ),
            ws_port: Arc::new(std::sync::atomic::AtomicU16::new(9847)),
            onboarded_marker_path: std::path::PathBuf::from("/tmp/tron-test-onboarded.marker"),
            release_fetcher: None,
            updater_state_path: std::path::PathBuf::from("/tmp/tron-test-updater-state.json"),
        };

        (tmp, ctx, sid)
    }

    #[tokio::test]
    async fn push_handler_protected_branch_returns_typed_code() {
        // The user-reported bug. Was `INTERNAL_ERROR`; now `PROTECTED_BRANCH`.
        let (_tmp, ctx, sid) = push_test_context().await;
        let err = PushHandler
            .handle(Some(json!({"sessionId": sid, "branch": "main"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(
            err.code(),
            "PROTECTED_BRANCH",
            "protected-branch push must surface typed code, got {err:?}"
        );
        assert!(
            err.to_string().contains("main"),
            "message should carry the branch name; got {err}"
        );
    }

    #[tokio::test]
    async fn push_handler_no_remote_returns_typed_code() {
        // Session has a worktree but no origin remote configured. scm::push
        // classifies this as NoRemoteConfigured; the handler must expose it
        // as NO_REMOTE, not INTERNAL_ERROR.
        let (_tmp, ctx, sid) = push_test_context().await;
        let err = PushHandler
            .handle(Some(json!({"sessionId": sid, "branch": "feature/x"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(
            err.code(),
            "NO_REMOTE",
            "missing-origin push must surface typed code, got {err:?}"
        );
    }

    #[tokio::test]
    async fn push_handler_no_session_returns_worktree_not_found() {
        // Coordinator is present but the session is unknown. Must surface
        // WORKTREE_NOT_FOUND (was INTERNAL_ERROR with a raw Rust message).
        let (_tmp, ctx, _sid) = push_test_context().await;
        let err = PushHandler
            .handle(
                Some(json!({
                    "sessionId": "session-that-does-not-exist",
                    "branch": "feature/x",
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(
            err.code(),
            "WORKTREE_NOT_FOUND",
            "unknown session must surface typed NotFound code, got {err:?}"
        );
    }

    #[tokio::test]
    async fn push_handler_missing_session_id_is_invalid_params() {
        // Preserves existing param-validation behavior across the refactor.
        let (_tmp, ctx, _sid) = push_test_context().await;
        let err = PushHandler.handle(Some(json!({})), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[test]
    fn sync_outcome_json_shapes() {
        let v = sync_outcome_json(&SyncOutcome::UpToDate { head: "abc".into() });
        assert_eq!(v["outcome"], "upToDate");

        let v = sync_outcome_json(&SyncOutcome::FastForwarded {
            old_head: "a".into(),
            new_head: "b".into(),
            advanced_by: 3,
        });
        assert_eq!(v["outcome"], "fastForwarded");
        assert_eq!(v["advancedBy"], 3);

        let v = sync_outcome_json(&SyncOutcome::Blocked(SyncBlockReason::DirtyWorkingTree));
        assert_eq!(v["outcome"], "blocked");
        assert_eq!(v["reason"], "dirtyWorkingTree");

        let v = sync_outcome_json(&SyncOutcome::Blocked(SyncBlockReason::Diverged {
            ahead: 2,
            behind: 3,
        }));
        assert_eq!(v["reason"], "diverged");
        assert_eq!(v["ahead"], 2);
        assert_eq!(v["behind"], 3);
    }
}
