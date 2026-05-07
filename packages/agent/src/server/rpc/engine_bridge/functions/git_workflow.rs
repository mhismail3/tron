//! Canonical git/worktree workflow engine functions.
//!
//! JSON-RPC now reaches these operations through `json_rpc` triggers targeting
//! canonical `git::*` and `worktree::*` function ids. The private operation
//! adapters below preserve the coordinator's Phase 3 behavior:
//! - `git.syncMain`, `git.push`, `git.listLocalBranches`
//! - `worktree.finalizeSession`
//! - `worktree.startMerge`, `worktree.listConflicts`,
//!   `worktree.resolveConflict`, `worktree.continueMerge`,
//!   `worktree.abortMerge`, `worktree.resolveConflictsWithSubagent`
//! - `repo.listSessions`, `repo.getDivergence`
//!
//! Operation implementations intentionally keep business logic minimal:
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

use super::RpcEngineDeps;
use crate::engine::Invocation;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let params = Some(invocation.payload.clone());
    let ctx = deps.rpc_context.as_ref();
    match method {
        "git.syncMain" => SyncMainHandler.handle(params, ctx).await,
        "git.push" => PushHandler.handle(params, ctx).await,
        "git.listLocalBranches" => ListLocalBranchesHandler.handle(params, ctx).await,
        "git.listRemoteBranches" => ListRemoteBranchesHandler.handle(params, ctx).await,
        "worktree.finalizeSession" => FinalizeSessionHandler.handle(params, ctx).await,
        "worktree.rebaseOnMain" => RebaseOnMainHandler.handle(params, ctx).await,
        "worktree.startMerge" => StartMergeHandler.handle(params, ctx).await,
        "worktree.listConflicts" => ListConflictsHandler.handle(params, ctx).await,
        "worktree.resolveConflict" => ResolveConflictHandler.handle(params, ctx).await,
        "worktree.continueMerge" => ContinueMergeHandler.handle(params, ctx).await,
        "worktree.abortMerge" => AbortMergeHandler.handle(params, ctx).await,
        "worktree.resolveConflictsWithSubagent" => {
            ResolveConflictsWithSubagentHandler
                .handle(params, ctx)
                .await
        }
        _ => Err(RpcError::Internal {
            message: format!("RPC method {method} is not git workflow-owned"),
        }),
    }
}

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
