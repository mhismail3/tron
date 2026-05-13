//! Canonical git/worktree workflow engine functions.
//!
//! Client protocols reach these operations through engine triggers targeting
//! canonical `git::*` and `worktree::*` function ids. The private operation
//! helpers preserve coordinator behavior for sync, push, branch listing,
//! finalize, merge/rebase, conflict resolution, and repo read capabilities.
//!
//! Operation implementations intentionally keep business logic minimal:
//! param extraction → coordinator call → JSON response. Event emission
//! (`WorktreeMainSynced`, `RepoMainAdvanced`, lock acquire/release, …) is
//! owned by the coordinator layer so it fires for every caller (capability,
//! engine transport, subagent).
//!
//! Error mapping: every coordinator error is routed through
//! `crate::shared::server::error_mapping::map_worktree_error`, which classifies `WorktreeError`
//! variants into typed capability error codes (`PROTECTED_BRANCH`,
//! `NON_FAST_FORWARD`, `NO_REMOTE`, `GIT_AUTH_FAILED`, …). Domain functions
//! should not produce `CapabilityError::Internal` for a predictable git failure; use
//! the helper instead.

use serde_json::{Value, json};

use crate::domains::worktree::types::{
    ConflictResolution, MergeStrategy, SyncBlockReason, SyncOutcome,
};
use crate::domains::worktree::{ConflictedFile, WorktreeCoordinator};
use crate::shared::server::errors::CapabilityError;
use std::path::PathBuf;

use super::Deps;

// ── Helpers ──────────────────────────────────────────────────────────

pub(super) fn require_coordinator(deps: &Deps) -> Result<&WorktreeCoordinator, CapabilityError> {
    deps.worktree_coordinator
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

/// Look up the session's original working directory so the coordinator
/// can fall back to it when the session has no isolated worktree
/// (passthrough mode — session on `main`, or post-finalize with no
/// rebranch). Returns `None` when the session isn't registered, which
/// is propagated as a normal "not found" error by the coordinator.
pub(super) fn session_working_dir(deps: &Deps, session_id: &str) -> Option<PathBuf> {
    deps.session_manager
        .get_session(session_id)
        .ok()
        .flatten()
        .map(|s| PathBuf::from(s.working_directory))
}

pub(super) fn parse_strategy(s: Option<&str>) -> MergeStrategy {
    match s {
        Some("rebase") => MergeStrategy::Rebase,
        Some("squash") => MergeStrategy::Squash,
        _ => MergeStrategy::Merge,
    }
}

/// Strategy parser for `worktree::rebase_on_main` — accepts only `"rebase"`
/// (default) or `"merge"`. `"squash"` and unknown values error with
/// `INVALID_PARAMS` so callers find out at the transport boundary rather than
/// deep in the coordinator.
pub(super) fn parse_rebase_strategy(s: Option<&str>) -> Result<MergeStrategy, CapabilityError> {
    match s {
        None | Some("rebase") => Ok(MergeStrategy::Rebase),
        Some("merge") => Ok(MergeStrategy::Merge),
        Some("squash") => Err(CapabilityError::InvalidParams {
            message: "rebaseOnMain does not accept 'squash'".into(),
        }),
        Some(other) => Err(CapabilityError::InvalidParams {
            message: format!("strategy must be 'rebase' or 'merge'; got '{other}'"),
        }),
    }
}

pub(super) fn parse_resolution(s: &str) -> Result<ConflictResolution, CapabilityError> {
    match s {
        "ours" => Ok(ConflictResolution::Ours),
        "theirs" => Ok(ConflictResolution::Theirs),
        "markResolved" | "mark_resolved" | "manual" => Ok(ConflictResolution::MarkResolved),
        other => Err(CapabilityError::InvalidParams {
            message: format!(
                "resolution must be one of 'ours' | 'theirs' | 'markResolved'; got '{other}'"
            ),
        }),
    }
}

pub(super) fn conflicted_file_json(f: &ConflictedFile) -> Value {
    // `ours` / `theirs` / `base` may be arbitrary bytes — expose as base64
    // so the iOS client can decide whether to decode as UTF-8 or render
    // as a binary summary.
    use base64::{Engine, engine::general_purpose::STANDARD as B64};
    let b64 = |b: &Option<Vec<u8>>| b.as_ref().map(|v| B64.encode(v));
    json!({
        "path": f.path,
        "isBinary": f.is_binary,
        "kind": match f.kind {
            crate::domains::worktree::types::ConflictKind::BothModified => "both_modified",
            crate::domains::worktree::types::ConflictKind::BothAdded => "both_added",
            crate::domains::worktree::types::ConflictKind::DeletedByUs => "deleted_by_us",
            crate::domains::worktree::types::ConflictKind::DeletedByThem => "deleted_by_them",
            crate::domains::worktree::types::ConflictKind::Rename => "rename",
            crate::domains::worktree::types::ConflictKind::Other => "other",
        },
        "base": b64(&f.base),
        "ours": b64(&f.ours),
        "theirs": b64(&f.theirs),
    })
}

pub(super) fn sync_outcome_json(o: &SyncOutcome) -> Value {
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
