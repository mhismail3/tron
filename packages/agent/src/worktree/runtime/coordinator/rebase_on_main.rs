//! Coordinator-level `rebase_on_main`: pulls main forward into an
//! active session's branch.
//!
//! Mirror of `finalize_session` in terms of locking + event emission,
//! but inverted: the write target is the session branch (not main).
//!
//! Flow:
//! 1. Preconditions (session exists, no pending merge, strategy != squash)
//! 2. Resolve main branch + ahead/behind via `queries::ahead_behind`
//! 3. `behind == 0` → `NoOp` short-circuit (no lock, no events, no stash)
//! 4. Acquire per-repo lock (serialises with `sync_main` / `finalize_session`)
//! 5. Snapshot pre-state (head, dirty?) and optionally stash + sidecar write
//! 6. Call `scm::conflict::start_merge_keep_conflicts` with flipped
//!    source/target (source = session branch, target = main) — the
//!    existing merge/rebase machinery does the rest
//! 7. Clean result → pop stash (if any), emit `worktree.rebased_on_main`,
//!    delete sidecar, update in-memory `WorktreeInfo.base_commit`
//! 8. Conflict result → attach `auto_stash_ref` to PendingMergeState,
//!    return `Conflicts { count }`. Conflict resolution path emits the
//!    final `rebased_on_main` via `continue_merge` (origin-aware).
//!
//! Invariant: `worktree.rebased_on_main` fires iff the session branch
//! tip moves to include main's commits — clean path OR post-resolution.
//! Never on abort.

use std::path::{Path, PathBuf};

use serde_json::json;
use tracing::{debug, warn};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::conflict as scm_conflict;
use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::types::{
    MergeOrigin, MergeStrategy, RebaseOnMainResult,
};

use super::repo_lock::LockedOp;
use super::WorktreeCoordinator;

/// Sidecar-file schema version. Bumping this invalidates old sidecars
/// (treated as corrupt and cleaned up on startup).
pub(super) const SIDECAR_VERSION: u32 = 1;

impl WorktreeCoordinator {
    /// Rebase (or merge) main's commits onto the session's branch.
    ///
    /// See module docs for the full flow. See the plan in
    /// `misty-toasting-lake.md` for the edge-case matrix this enumerates.
    pub async fn rebase_on_main(
        &self,
        session_id: &str,
        main_branch: Option<&str>,
        strategy: MergeStrategy,
    ) -> Result<RebaseOnMainResult> {
        // ── 1. Pre-op guards (no git, no lock) ────────────────────────
        if matches!(strategy, MergeStrategy::Squash) {
            return Err(WorktreeError::InvalidSessionState(
                "squash is not a valid rebase-on-main strategy".into(),
            ));
        }

        let info = self
            .state
            .lock()
            .active_info(session_id)
            .ok_or_else(|| WorktreeError::NotFound { session_id: session_id.to_string() })?;

        if self.state.lock().pending_merges.contains_key(session_id) {
            return Err(WorktreeError::PendingMergeExists);
        }

        let resolved_main = match main_branch.map(str::to_string).or(info.base_branch.clone()) {
            Some(b) if !b.is_empty() => b,
            _ => return Err(WorktreeError::MissingBaseBranch),
        };

        if resolved_main == info.branch {
            return Err(WorktreeError::InvalidSessionState(
                "session branch equals main branch; nothing to rebase".into(),
            ));
        }

        // Verify both refs resolve. Main must exist locally; session branch
        // should also resolve (if it doesn't, the session state is corrupt).
        if self
            .git
            .rev_parse_verify(&info.repo_root, &resolved_main)
            .await
            .is_err()
        {
            return Err(WorktreeError::RefNotFound(resolved_main));
        }
        if self
            .git
            .rev_parse_verify(&info.worktree_path, "HEAD")
            .await
            .is_err()
        {
            return Err(WorktreeError::InvalidSessionState(
                "session worktree HEAD does not resolve".into(),
            ));
        }
        // Refuse detached HEAD — `current_branch` uses `symbolic-ref` and
        // errors when HEAD is detached.
        if self
            .git
            .current_branch(&info.worktree_path)
            .await
            .is_err()
        {
            return Err(WorktreeError::InvalidSessionState(
                "session worktree is on detached HEAD".into(),
            ));
        }

        // ── 2. Divergence probe (no lock yet — cheap read) ────────────
        let (ahead, behind) = self
            .ahead_behind(&info.repo_root, &resolved_main, &info.branch)
            .await
            .map_err(|e| WorktreeError::Git(e.to_string()))?;

        if behind == 0 {
            // Already up to date. No lock, no events, no stash.
            debug!(session_id, ahead, behind, "rebase_on_main: no-op");
            return Ok(RebaseOnMainResult::NoOp { ahead });
        }

        // ── 3. Acquire repo lock for the full critical section ────────
        let _guard = self
            .acquire_repo_lock(&info.repo_root, session_id, LockedOp::RebaseOnMain)
            .await;

        // ── 4. Snapshot pre-op state ──────────────────────────────────
        let old_base_commit = self
            .git
            .head_commit(&info.worktree_path)
            .await
            .unwrap_or_default();

        let is_dirty = self
            .git
            .has_changes(&info.worktree_path)
            .await
            .unwrap_or(false);

        // ── 5. Auto-stash (if dirty) + sidecar persistence ────────────
        let auto_stash_ref: Option<String> = if is_dirty {
            let stash_ref = self
                .git
                .stash_create_with_untracked(
                    &info.worktree_path,
                    &format!("tron-rebase-on-main:{session_id}"),
                )
                .await?;
            // Persist sidecar BEFORE touching merge state so crash recovery
            // can always find the stash. `write_sidecar` is atomic (temp
            // file + rename).
            if let Err(e) = write_sidecar(
                &info.worktree_path,
                &SidecarContents {
                    version: SIDECAR_VERSION,
                    session_id: session_id.to_string(),
                    stash_ref: stash_ref.clone(),
                    strategy: strategy.as_str().to_string(),
                },
            )
            .await
            {
                // Sidecar write failure → rollback: pop stash to restore
                // user state, then surface the error.
                warn!(session_id, error = %e, "sidecar write failed; rolling back stash");
                let _ = self.git.stash_pop(&info.worktree_path, &stash_ref).await;
                return Err(WorktreeError::Io(e));
            }
            Some(stash_ref)
        } else {
            None
        };

        // ── 6. Start the merge/rebase ─────────────────────────────────
        // Per strategy, source/target map differently:
        //   Rebase  — `git checkout source; git rebase target`
        //              → source=session_branch, target=main.
        //              Session commits get replayed onto main.
        //   Merge   — `git checkout target; git merge source`
        //              → source=main, target=session_branch.
        //              Main's commits land on the session branch as a
        //              merge commit.
        //
        // IMPORTANT: pass the WORKTREE path (not repo_root). The session
        // branch is checked out in the worktree; running `git checkout`
        // for it in the repo root would fail with "already used by
        // worktree". Running inside the worktree: session-branch checkout
        // is a no-op, main-branch checkout is what we can't do from
        // rebase_on_main (main is at repo_root) — so the Merge-strategy
        // path uses `target=session_branch` which IS already checked out
        // in the worktree, avoiding that footgun.
        let (src, tgt) = match strategy {
            MergeStrategy::Rebase => (info.branch.clone(), resolved_main.clone()),
            MergeStrategy::Merge => (resolved_main.clone(), info.branch.clone()),
            // Squash was rejected above in the pre-op guards.
            MergeStrategy::Squash => unreachable!("squash rejected in preconditions"),
        };
        let mut pending = scm_conflict::start_merge_keep_conflicts(
            &info.worktree_path,
            session_id,
            &src,
            &tgt,
            strategy.clone(),
            MergeOrigin::RebaseOnMain,
            &self.git,
        )
        .await?;
        pending.auto_stash_ref = auto_stash_ref.clone();

        // Probe conflicts after start (also in worktree).
        let conflict_paths: Vec<String> = scm_conflict::list_conflicts(
            &info.worktree_path,
            strategy.clone(),
            &self.git,
        )
        .await
        .map(|v| v.into_iter().map(|c| c.path).collect())
        .unwrap_or_default();

        // ── 7. Conflict path: stash conflicts-pending state + return ──
        if !conflict_paths.is_empty() {
            self.state
                .lock()
                .pending_merges
                .insert(session_id.to_string(), pending.clone());

            // Emit merge-started + conflict-detected so the iOS flow
            // identically mirrors the existing conflict UX. Use the
            // strategy-specific source/target ordering so iOS banners
            // render the right direction.
            let strategy_str = strategy.as_str().to_string();
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeMergeStarted,
                payload: json!({
                    "sourceBranch": src,
                    "targetBranch": tgt,
                    "strategy": strategy_str,
                    "conflictCount": conflict_paths.len() as u32,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreeMergeStarted {
                base: BaseEvent::now(session_id),
                source_branch: src.clone(),
                target_branch: tgt.clone(),
                strategy: strategy_str.clone(),
                conflict_count: conflict_paths.len() as u32,
            });
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreeConflictDetected,
                payload: json!({
                    "sourceBranch": src,
                    "targetBranch": tgt,
                    "origin": MergeOrigin::RebaseOnMain.as_str(),
                    "paths": conflict_paths,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreeConflictDetected {
                base: BaseEvent::now(session_id),
                source_branch: src.clone(),
                target_branch: tgt.clone(),
                origin: MergeOrigin::RebaseOnMain.as_str().to_string(),
                paths: conflict_paths.clone(),
            });

            return Ok(RebaseOnMainResult::Conflicts {
                count: conflict_paths.len(),
            });
        }

        // ── 8. Clean path: pop stash (if any), emit, update state ─────
        let new_base_commit = self
            .git
            .head_commit(&info.worktree_path)
            .await
            .unwrap_or_default();

        let had_auto_stash = auto_stash_ref.is_some();
        if let Some(ref stash_ref) = auto_stash_ref {
            let pop_result = self.git.stash_pop(&info.worktree_path, stash_ref).await;
            // Helper populates pending_merges with StashPop origin if pop
            // conflicts, emits both post_rebase_stash_conflict and
            // conflict_detected, and no-ops on clean pop. A conflicted
            // pop leaves the stash on the stack; sidecar cleanup stays
            // below so we retain crash-recovery state for the unresolved
            // pop until the user explicitly continues or aborts.
            self.handle_post_stash_pop(session_id, stash_ref, pop_result);
        }

        // Sidecar clean-up runs only when the clean path finished without
        // populating a StashPop pending merge. Check before removing.
        let still_pending = self
            .state
            .lock()
            .pending_merges
            .contains_key(session_id);
        if !still_pending {
            let _ = remove_sidecar(&info.worktree_path, session_id).await;
        }

        // Update in-memory WorktreeInfo.
        {
            let mut state = self.state.lock();
            if let Some(info) = state.active_by_session.get_mut(session_id) {
                info.base_commit = new_base_commit.clone();
            }
        }

        // Emit the "rebased_on_main" event.
        let strategy_str = strategy.as_str().to_string();
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::WorktreeRebasedOnMain,
            payload: json!({
                "mainBranch": resolved_main,
                "strategy": strategy_str,
                "oldBaseCommit": old_base_commit,
                "newBaseCommit": new_base_commit,
                "mainCommitsIncorporated": behind as u64,
                "hadAutoStash": had_auto_stash,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::WorktreeRebasedOnMain {
            base: BaseEvent::now(session_id),
            main_branch: resolved_main,
            strategy: strategy_str,
            old_base_commit: old_base_commit.clone(),
            new_base_commit: new_base_commit.clone(),
            main_commits_incorporated: behind as u64,
            had_auto_stash,
        });

        Ok(RebaseOnMainResult::Success {
            old_base_commit,
            new_base_commit,
            main_commits_incorporated: behind,
            strategy,
            had_auto_stash,
        })
    }
}

// ─────────────────────────────────────────────────────────────────────
// Sidecar helpers — small serde-backed JSON file in `.git/` so crash
// recovery can find an orphan stash.
//
// INVARIANT: sidecar file exists iff `PendingMergeState.auto_stash_ref.is_some()`
// for this session. Produced by `write_sidecar` atomically before any
// git mutation; consumed by `recovery::rebuild_pending_merges` / removed
// on clean completion and on abort.
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct SidecarContents {
    pub version: u32,
    pub session_id: String,
    pub stash_ref: String,
    pub strategy: String,
}

/// Resolve the sidecar path for a session inside a worktree.
/// Uses the worktree's `.git` dir (which, for a linked worktree, is the
/// per-worktree `.git/worktrees/<name>/` directory — `git_dir_path` handles
/// the indirection).
pub(super) async fn sidecar_path(
    worktree: &Path,
    session_id: &str,
) -> std::io::Result<PathBuf> {
    // The git executor returns the `.git` dir directly; we can shell it
    // ourselves to avoid taking a GitExecutor dependency here. Use the
    // common case: `<worktree>/.git`, and fall back to `git rev-parse
    // --git-dir` if that isn't a directory.
    let default = worktree.join(".git");
    if default.is_dir() {
        return Ok(default.join(format!("tron-rebase-stash-{session_id}.json")));
    }
    // Linked worktrees have a `.git` FILE containing `gitdir: <path>`.
    // We shell out to git to resolve it reliably.
    let output = tokio::process::Command::new("git")
        .args(["rev-parse", "--git-dir"])
        .current_dir(worktree)
        .output()
        .await?;
    let git_dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let git_dir_path = PathBuf::from(git_dir);
    let absolute = if git_dir_path.is_absolute() {
        git_dir_path
    } else {
        worktree.join(git_dir_path)
    };
    Ok(absolute.join(format!("tron-rebase-stash-{session_id}.json")))
}

/// Atomically write the sidecar file (tempfile + rename).
pub(super) async fn write_sidecar(
    worktree: &Path,
    contents: &SidecarContents,
) -> std::io::Result<()> {
    let path = sidecar_path(worktree, &contents.session_id).await?;
    let tmp = path.with_extension("json.tmp");
    if let Some(parent) = tmp.parent() {
        tokio::fs::create_dir_all(parent).await.ok();
    }
    let body = serde_json::to_vec_pretty(contents)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    tokio::fs::write(&tmp, body).await?;
    tokio::fs::rename(&tmp, &path).await?;
    Ok(())
}

/// Remove a sidecar (idempotent — missing file is OK).
pub(super) async fn remove_sidecar(
    worktree: &Path,
    session_id: &str,
) -> std::io::Result<()> {
    let path = sidecar_path(worktree, session_id).await?;
    match tokio::fs::remove_file(&path).await {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// Enumerate sidecars in a worktree's `.git/` directory.
/// Returns `(session_id, contents)` tuples. Corrupted files are logged
/// and skipped (caller sees them as "no sidecar present").
pub(super) async fn read_sidecars_for_worktree(
    worktree: &Path,
) -> Vec<(String, Option<SidecarContents>)> {
    let git_dir = match sidecar_path(worktree, "__probe__").await {
        Ok(p) => p.parent().map(PathBuf::from).unwrap_or_default(),
        Err(_) => return Vec::new(),
    };
    let mut out = Vec::new();
    let Ok(mut rd) = tokio::fs::read_dir(&git_dir).await else {
        return Vec::new();
    };
    while let Ok(Some(entry)) = rd.next_entry().await {
        let name = entry.file_name();
        let Some(n) = name.to_str() else { continue };
        let Some(session_id) = n
            .strip_prefix("tron-rebase-stash-")
            .and_then(|s| s.strip_suffix(".json"))
        else {
            continue;
        };
        let session_id = session_id.to_string();
        let body = match tokio::fs::read(entry.path()).await {
            Ok(b) => b,
            Err(_) => {
                out.push((session_id, None));
                continue;
            }
        };
        let parsed: Option<SidecarContents> = serde_json::from_slice(&body)
            .ok()
            .filter(|c: &SidecarContents| c.version == SIDECAR_VERSION);
        out.push((session_id, parsed));
    }
    out
}

#[cfg(test)]
#[path = "rebase_on_main_tests.rs"]
mod tests;
