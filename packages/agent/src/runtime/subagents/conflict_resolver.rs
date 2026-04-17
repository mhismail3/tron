//! Conflict resolver subagent — drives git merge conflict resolution.
//!
//! Spawned by the `worktree.resolveConflictsWithSubagent` RPC once the
//! user has tapped "Let Resolver Run" on the iOS conflict sub-sheet. The
//! subagent runs inside the same worktree as the parent session with a
//! restricted tool allowlist (`Read`, `Edit`, `Write`, `Bash`) and drives
//! the merge entirely via `git` shell commands. It is expected to
//! complete the merge with `git commit --no-edit` (or
//! `git rebase --continue`) before terminating.
//!
//! ## Failure handling
//!
//! After the subagent finishes (successfully or via turn-limit
//! exhaustion), the coordinator reconciles its in-memory merge state
//! with the on-disk state:
//!
//! - If the subagent completed the merge (no `.git/MERGE_HEAD` /
//!   `.git/rebase-merge/`), `reconcile_completed_merge` clears the
//!   pending-merges cache and emits `WorktreeMergeContinued`.
//! - Otherwise the coordinator calls [`abort_merge_with_reason`] with
//!   reason `"subagent_failed"`, emitting
//!   `WorktreeMergeAborted { reason: "subagent_failed" }` so iOS can
//!   surface the failure banner.
//!
//! [`abort_merge_with_reason`]: crate::worktree::WorktreeCoordinator::abort_merge_with_reason

use std::sync::Arc;

use serde_json::json;
use tracing::{info, warn};

use crate::runtime::orchestrator::subagent_manager::{
    SpawnType, SubagentManager, SubsessionConfig,
};
use crate::tools::traits::SubagentOps;
use crate::worktree::WorktreeCoordinator;
use crate::worktree::types::ConflictedFile;

/// Restricted tool allowlist for the conflict resolver subagent.
///
/// Any tool not in this list is stripped from the inherited tool
/// registry before the subagent starts — new tools added to the
/// top-level registry never silently leak into the restricted resolver.
pub const CONFLICT_RESOLVER_ALLOWED_TOOLS: &[&str] =
    &["Read", "Edit", "Write", "Bash"];

/// Default maximum number of LLM turns for a conflict-resolver session.
pub const DEFAULT_MAX_TURNS: u32 = 40;

/// System prompt for the conflict-resolver subagent.
///
/// Rendered by [`build_prompt`] with the live merge context (source,
/// target, strategy, conflicted file list) appended as a trailing
/// "## Current Merge" section so the subagent starts with a concrete
/// picture of the work ahead.
pub const CONFLICT_RESOLVER_BASE_PROMPT: &str = r#"You are the Tron conflict-resolver subagent.

A merge in the current session worktree produced conflicts. Your job is to resolve every conflicted file and finalise the merge by creating the merge commit (or `rebase --continue`). You work in the worktree directory your shell starts in — **all `git` commands run there**.

## Tools

Your only tools: `Read`, `Edit`, `Write`, `Bash`. Drive git entirely through `Bash`. There are no typed git tools — use the standard CLI.

- `Read` — inspect conflicted files (they contain `<<<<<<<` / `=======` / `>>>>>>>` markers).
- `Edit` / `Write` — produce the final resolved content.
- `Bash` — run `git` (and **only** `git`, plus read-only helpers like `cat`/`head` if needed).

## Inspecting the conflict set

- Enumerate conflicts: `git diff --name-only --diff-filter=U` (one path per line).
- Detailed status (rename / both-added / delete-by-us / etc.): `git status --porcelain=v1`. Two-letter codes: `UU`=both modified, `AA`=both added, `DU`=deleted-by-us, `UD`=deleted-by-them, `AU`=added-by-us, `UA`=added-by-them, `DD`=both deleted.
- Base/ours/theirs content for a path: `git show :1:<path>` (base), `git show :2:<path>` (ours), `git show :3:<path>` (theirs). Useful when the semantic intent is ambiguous.
- Recent context: `git log --oneline -20 <branch>` on either side.

## Detecting whether you're in a merge or a rebase

- Merge in progress: `.git/MERGE_HEAD` exists. Finish with `git commit --no-edit`.
- Rebase in progress: `.git/rebase-merge/` or `.git/rebase-apply/` exists. Finish with `git rebase --continue` (may need to repeat if later commits also conflict).

Check with: `ls -d .git/MERGE_HEAD .git/rebase-merge .git/rebase-apply 2>/dev/null || true` (any that exist will print).

## Resolving a single file

Pick **one** of:

1. **Take ours** (keep the session branch's version wholesale):
   `git checkout --ours -- <path> && git add -- <path>`
2. **Take theirs** (keep the incoming branch's version wholesale):
   `git checkout --theirs -- <path> && git add -- <path>`
3. **Manual merge** (semantic reconciliation):
   - `Read` the conflicted file.
   - `Edit` it to produce valid, marker-free content that preserves both sides' intent.
   - `git add -- <path>` to stage the resolution.
4. **Resolve a delete conflict** (`DU`/`UD`): decide whether the file should exist.
   - Keep deleted: `git rm -- <path>`.
   - Keep content: `git checkout --ours -- <path>` or `--theirs -- <path>`, then `git add -- <path>`.

## Finalising

1. Run `git diff --name-only --diff-filter=U` — the output MUST be empty. If not, you still have work.
2. If merge: `git commit --no-edit` (keeps the default merge message git prepared). If the default message was cleared or you need a specific message: `git commit -m "<message>"`.
3. If rebase: `git rebase --continue`. If it stops again with conflicts, repeat the loop for the next commit.
4. Verify with `git status` — should report a clean working tree with no merge/rebase in progress.

## Abort path (last resort)

If conflicts are genuinely irreconcilable (both sides semantically correct with no valid merger), abort:
- Merge: `git merge --abort`.
- Rebase: `git rebase --abort`.

Then emit a final message explaining **why** each specific file couldn't be resolved.

## Rules

- **NEVER** modify unrelated files. Only touch the conflicted set.
- **NEVER** stage or commit with `<<<<<<<` / `=======` / `>>>>>>>` markers still present. Always verify with `grep -n '<<<<<<< \|=======\|>>>>>>> ' <path>` before `git add`.
- **NEVER** run `git push`, `git reset --hard`, `git checkout <branch>`, `git switch <branch>`, or any command that moves branch refs or discards work beyond the abort commands above.
- **NEVER** spawn another subagent. Do your own work.
- Be terse. Status streams live to an iOS sub-sheet — do not chatter.
"#;

/// Render the full subagent system prompt with merge context appended.
pub fn build_prompt(
    source_branch: &str,
    target_branch: &str,
    strategy: &str,
    conflicts: &[ConflictedFile],
) -> String {
    let mut out = String::with_capacity(CONFLICT_RESOLVER_BASE_PROMPT.len() + 512);
    out.push_str(CONFLICT_RESOLVER_BASE_PROMPT);
    out.push_str("\n\n## Current Merge\n\n");
    out.push_str(&format!("- Source branch: `{source_branch}`\n"));
    out.push_str(&format!("- Target branch: `{target_branch}`\n"));
    out.push_str(&format!("- Strategy: `{strategy}`\n"));
    out.push_str(&format!("- Conflicted files ({}):\n", conflicts.len()));
    for f in conflicts {
        out.push_str(&format!(
            "  - `{}` ({}{})\n",
            f.path,
            conflict_kind_label(&f.kind),
            if f.is_binary { ", binary" } else { "" }
        ));
    }
    out
}

fn conflict_kind_label(kind: &crate::worktree::types::ConflictKind) -> &'static str {
    use crate::worktree::types::ConflictKind;
    match kind {
        ConflictKind::BothModified => "both_modified",
        ConflictKind::BothAdded => "both_added",
        ConflictKind::DeletedByUs => "deleted_by_us",
        ConflictKind::DeletedByThem => "deleted_by_them",
        ConflictKind::Rename => "rename",
        ConflictKind::Other => "other",
    }
}

/// Outcome of a conflict-resolver spawn attempt.
#[derive(Debug)]
pub struct SpawnOutcome {
    /// `true` when the subagent was spawned.
    pub spawned: bool,
    /// Child session ID (when `spawned == true`).
    pub subagent_session_id: Option<String>,
    /// Human-readable reason (populated when `spawned == false`).
    pub reason: Option<String>,
}

/// Spawn the conflict-resolver subagent for `parent_session_id`.
///
/// Looks up the session's worktree + pending merge state via `coord`,
/// builds the live system prompt, and hands off to the `SubagentManager`
/// as a non-blocking [`SpawnType::Subsession`] (so the caller — an RPC
/// handler — can return immediately while the subagent works).
///
/// Auto-abort on failure is wired via a post-completion watcher task
/// that polls `coord.pending_merge(session_id)` once the subagent
/// finishes; if the merge is still pending, it calls
/// `abort_merge_with_reason(sid, "subagent_failed")`.
pub async fn spawn(
    manager: Arc<SubagentManager>,
    coord: Arc<WorktreeCoordinator>,
    parent_session_id: &str,
) -> SpawnOutcome {
    // Resolve the worktree context — we need the working directory and
    // pending merge state to shape the subagent prompt.
    let Some(info) = coord.get_info(parent_session_id) else {
        return SpawnOutcome {
            spawned: false,
            subagent_session_id: None,
            reason: Some("session has no active worktree".into()),
        };
    };
    let Some(pending) = coord.pending_merge(parent_session_id) else {
        return SpawnOutcome {
            spawned: false,
            subagent_session_id: None,
            reason: Some("session has no pending merge".into()),
        };
    };

    let conflicts = coord
        .list_conflicts(parent_session_id)
        .await
        .unwrap_or_default();
    if conflicts.is_empty() {
        return SpawnOutcome {
            spawned: false,
            subagent_session_id: None,
            reason: Some("no conflicted files found".into()),
        };
    }

    let strategy_label = match pending.strategy {
        crate::worktree::types::MergeStrategy::Merge => "merge",
        crate::worktree::types::MergeStrategy::Rebase => "rebase",
        crate::worktree::types::MergeStrategy::Squash => "squash",
    };

    let prompt = build_prompt(
        &pending.source_branch,
        &pending.target_branch,
        strategy_label,
        &conflicts,
    );

    let task = format!(
        "Resolve the {} conflicted files from merging `{}` into `{}` ({}). Run `git diff --name-only --diff-filter=U` to enumerate, resolve each file, then finalise with `git commit --no-edit` (merge) or `git rebase --continue` (rebase).",
        conflicts.len(),
        pending.source_branch,
        pending.target_branch,
        strategy_label,
    );

    let working_directory = info.worktree_path.to_string_lossy().to_string();
    let allowed: Vec<String> = CONFLICT_RESOLVER_ALLOWED_TOOLS
        .iter()
        .map(|s| (*s).to_string())
        .collect();

    let config = SubsessionConfig {
        parent_session_id: parent_session_id.to_string(),
        task,
        model: None, // inherit parent's configured subagent model
        system_prompt: prompt,
        working_directory,
        timeout_ms: 15 * 60 * 1000,
        blocking_timeout_ms: None, // non-blocking — RPC returns immediately
        max_turns: DEFAULT_MAX_TURNS,
        max_depth: 0,
        inherit_tools: true,
        denied_tools: vec![],
        allowed_tools: Some(allowed),
        reasoning_level: None,
        spawn_type: SpawnType::Subsession,
    };

    let outcome = match manager.spawn_subsession(config).await {
        Ok(out) => out,
        Err(error) => {
            warn!(
                session_id = %parent_session_id,
                error = %error,
                "conflict-resolver subagent spawn failed"
            );
            return SpawnOutcome {
                spawned: false,
                subagent_session_id: None,
                reason: Some(format!("spawn failed: {error}")),
            };
        }
    };

    info!(
        parent_session_id = %parent_session_id,
        subagent_session_id = %outcome.session_id,
        conflicts = conflicts.len(),
        "spawned conflict-resolver subagent"
    );

    // Schedule auto-abort watcher: once the subagent completes (success
    // OR failure), check whether the merge is still pending on the
    // coordinator. If it is, the subagent gave up without committing —
    // auto-abort the merge so the worktree returns to a clean state.
    schedule_auto_abort_watcher(
        manager.clone(),
        coord.clone(),
        parent_session_id.to_string(),
        outcome.session_id.clone(),
    );

    SpawnOutcome {
        spawned: true,
        subagent_session_id: Some(outcome.session_id),
        reason: None,
    }
}

/// Spawn a background task that waits for the subagent to finish and
/// then auto-aborts the merge if it's still pending.
fn schedule_auto_abort_watcher(
    manager: Arc<SubagentManager>,
    coord: Arc<WorktreeCoordinator>,
    parent_session_id: String,
    subagent_session_id: String,
) {
    drop(tokio::spawn(async move {
        // Wait up to 30 minutes for the subagent to finish. The
        // per-turn model timeout + max_turns will converge on a bound
        // much shorter than this — 30m is a belt-and-braces safety net.
        let max_wait_ms = 30 * 60 * 1000;
        let _ = manager
            .wait_for_agents(
                &[subagent_session_id.clone()],
                crate::tools::traits::WaitMode::All,
                max_wait_ms,
            )
            .await;

        // Reconcile: the subagent drives git via raw shell, so the merge
        // may be complete on disk while the in-memory cache still tracks
        // it. `reconcile_completed_merge` checks the on-disk state and
        // either emits the merge-continued event (done) or reports the
        // merge is still live (failed).
        match coord.reconcile_completed_merge(&parent_session_id).await {
            Ok(true) => {
                info!(
                    parent_session_id = %parent_session_id,
                    subagent_session_id = %subagent_session_id,
                    "conflict-resolver subagent completed merge via raw git; reconciled"
                );
            }
            Ok(false) => {
                // Merge still pending on disk — subagent never finished.
                match coord
                    .abort_merge_with_reason(&parent_session_id, "subagent_failed")
                    .await
                {
                    Ok(()) => {
                        info!(
                            parent_session_id = %parent_session_id,
                            subagent_session_id = %subagent_session_id,
                            "auto-aborted merge after conflict-resolver subagent failed to continue"
                        );
                    }
                    Err(error) => {
                        warn!(
                            parent_session_id = %parent_session_id,
                            subagent_session_id = %subagent_session_id,
                            error = %error,
                            "auto-abort failed after subagent did not continue merge"
                        );
                    }
                }
            }
            Err(crate::worktree::errors::WorktreeError::NoPendingMerge) => {
                // Cache was already cleared (e.g. user manually aborted
                // while the subagent was running). Nothing to do.
                info!(
                    parent_session_id = %parent_session_id,
                    subagent_session_id = %subagent_session_id,
                    "conflict-resolver subagent completed with no pending merge"
                );
            }
            Err(error) => {
                warn!(
                    parent_session_id = %parent_session_id,
                    subagent_session_id = %subagent_session_id,
                    error = %error,
                    "reconcile_completed_merge failed after subagent finished"
                );
            }
        }
        // Silence unused — keeps the shape stable when logging is cfg'd off.
        let _ = json!({});
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worktree::types::{ConflictKind, ConflictedFile};

    fn mk(path: &str, kind: ConflictKind, binary: bool) -> ConflictedFile {
        ConflictedFile {
            path: path.into(),
            is_binary: binary,
            base: None,
            ours: None,
            theirs: None,
            kind,
        }
    }

    #[test]
    fn build_prompt_includes_merge_context() {
        let conflicts = vec![
            mk("a.rs", ConflictKind::BothModified, false),
            mk("assets/image.png", ConflictKind::BothAdded, true),
        ];
        let out = build_prompt("feature/x", "main", "merge", &conflicts);
        assert!(out.contains("## Current Merge"));
        assert!(out.contains("feature/x"));
        assert!(out.contains("main"));
        assert!(out.contains("`merge`"));
        assert!(out.contains("a.rs"));
        assert!(out.contains("both_modified"));
        assert!(out.contains("image.png"));
        assert!(out.contains("binary"));
    }

    #[test]
    fn build_prompt_lists_zero_conflicts_gracefully() {
        let out = build_prompt("a", "b", "rebase", &[]);
        assert!(out.contains("Conflicted files (0)"));
    }

    #[test]
    fn allowlist_is_stable() {
        // Guard rail — any change to the allowlist is a conscious one.
        // The resolver drives git entirely through Bash; no typed git
        // tools exist in the registry.
        assert_eq!(
            CONFLICT_RESOLVER_ALLOWED_TOOLS,
            &["Read", "Edit", "Write", "Bash"],
        );
        // Must NOT expose SpawnSubagent to prevent recursive resolver
        // spawning.
        assert!(!CONFLICT_RESOLVER_ALLOWED_TOOLS.contains(&"SpawnSubagent"));
    }
}
