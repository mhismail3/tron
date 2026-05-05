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
use crate::tools::traits::{SubagentOps, WaitMode};
use crate::worktree::WorktreeCoordinator;
use crate::worktree::types::ConflictedFile;

/// Grace period (ms) granted to the subagent to drain its turn after
/// wall-clock cancellation — the turn-abort path needs to unwind
/// model/tool calls, emit the final event, and release the tracker
/// notify before `reconcile_completed_merge` runs. Without this drain
/// the reconciler may observe an in-flight merge state.
const CANCEL_DRAIN_MS: u64 = 30_000;

/// Fallback tool allowlist used only if profile recovery is in progress.
const FALLBACK_ALLOWED_TOOLS: &[&str] = &["Read", "Edit", "Write", "Bash"];
/// Fallback maximum number of LLM turns used only during profile recovery.
const FALLBACK_MAX_TURNS: u32 = 40;
/// Fallback wall-clock cap used only during profile recovery.
const FALLBACK_TIMEOUT_MS: u64 = 15 * 60 * 1000;

/// System prompt for the conflict-resolver subagent.
///
/// Rendered by [`build_prompt`] with the live merge context (source,
/// target, strategy, conflicted file list) appended as a trailing
/// Render the full subagent system prompt with merge context appended.
pub fn build_prompt(
    source_branch: &str,
    target_branch: &str,
    strategy: &str,
    conflicts: &[ConflictedFile],
) -> String {
    let base_prompt =
        crate::runtime::context::instruction_prompts::process_prompt("conflictResolver");
    let mut out = String::with_capacity(base_prompt.len() + 512);
    out.push_str(&base_prompt);
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

    let process = crate::core::profile::active_process_spec("conflictResolver");
    let working_directory = info.worktree_path.to_string_lossy().to_string();
    let allowed: Vec<String> = process
        .as_ref()
        .and_then(|p| p.allowed_tools.clone())
        .unwrap_or_else(|| {
            FALLBACK_ALLOWED_TOOLS
                .iter()
                .map(|s| (*s).to_string())
                .collect()
        });

    let config = SubsessionConfig {
        parent_session_id: parent_session_id.to_string(),
        task,
        model: None, // inherit parent's configured subagent model
        system_prompt: prompt,
        working_directory,
        // Wall-clock cap for the non-blocking spawn — enforced by the
        // auto-abort watcher (see `schedule_auto_abort_watcher`). This
        // is the only place `timeout_ms` does work on a non-blocking
        // subsession, so keep the value in sync with the conflict-
        // resolver's tolerance: 15 min is generous given max 40 turns
        // at typical 15–20 s/turn, but still well below the prior
        // hardcoded 30 min which allowed runaway resolvers to keep
        // burning the model budget after they were clearly stuck.
        timeout_ms: process
            .as_ref()
            .and_then(|p| p.timeout_ms)
            .unwrap_or(FALLBACK_TIMEOUT_MS),
        blocking_timeout_ms: None,
        max_turns: process
            .as_ref()
            .and_then(|p| p.max_turns)
            .unwrap_or(FALLBACK_MAX_TURNS),
        max_depth: process.as_ref().and_then(|p| p.max_depth).unwrap_or(0),
        inherit_tools: process
            .as_ref()
            .and_then(|p| p.inherit_tools)
            .unwrap_or(true),
        denied_tools: process
            .as_ref()
            .map(|p| p.denied_tools.clone())
            .unwrap_or_default(),
        allowed_tools: Some(allowed),
        reasoning_level: None,
        spawn_type: SpawnType::Subsession,
    };

    let wall_clock_timeout_ms = config.timeout_ms;
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
    //
    // The watcher also enforces `wall_clock_timeout_ms` as an upper
    // bound on the subagent's runtime: on timeout it calls
    // `cancel_subagent` to stop the agent loop, drains the tracker,
    // then runs the same reconcile flow.
    schedule_auto_abort_watcher(
        manager.clone(),
        coord.clone(),
        parent_session_id.to_string(),
        outcome.session_id.clone(),
        wall_clock_timeout_ms,
    );

    SpawnOutcome {
        spawned: true,
        subagent_session_id: Some(outcome.session_id),
        reason: None,
    }
}

/// Wait for the subagent to finish within `wall_clock_timeout_ms`; on
/// timeout, cancel it and briefly drain so the tracker reports
/// completion before the caller reconciles coordinator state.
///
/// Returns `true` if the subagent completed on its own, `false` if the
/// wall clock fired and the subagent was cancelled.
///
/// INVARIANT: on timeout, `cancel_subagent` is always called before the
/// function returns. Without cancellation the agent loop would continue
/// running in the background (burning turns/model budget) even after
/// the watcher has already decided to abort the merge.
async fn wait_or_cancel(
    manager: &dyn SubagentOps,
    subagent_session_id: &str,
    wall_clock_timeout_ms: u64,
) -> bool {
    let session = [subagent_session_id.to_string()];
    if manager
        .wait_for_agents(&session, WaitMode::All, wall_clock_timeout_ms)
        .await
        .is_ok()
    {
        return true;
    }
    // Wall-clock fired — cancel the agent loop. Errors are logged but
    // do not stop the drain: a "not found" here means the subagent
    // already finished in the interim, which is fine.
    if let Err(error) = manager.cancel_subagent(subagent_session_id) {
        warn!(
            subagent_session_id,
            error = %error,
            "cancel_subagent failed during conflict-resolver timeout handling"
        );
    }
    // Drain: give the cancelled agent a bounded window to unwind the
    // current turn and mark its tracker complete. Reconciliation needs
    // a consistent view of the merge state, so races against an
    // in-flight `git commit` are worth avoiding.
    let _ = manager
        .wait_for_agents(&session, WaitMode::All, CANCEL_DRAIN_MS)
        .await;
    false
}

/// Spawn a background task that waits for the subagent to finish and
/// then auto-aborts the merge if it's still pending.
fn schedule_auto_abort_watcher(
    manager: Arc<SubagentManager>,
    coord: Arc<WorktreeCoordinator>,
    parent_session_id: String,
    subagent_session_id: String,
    wall_clock_timeout_ms: u64,
) {
    drop(tokio::spawn(async move {
        let manager_ops: Arc<dyn SubagentOps> = manager;
        let completed = wait_or_cancel(
            manager_ops.as_ref(),
            &subagent_session_id,
            wall_clock_timeout_ms,
        )
        .await;
        if !completed {
            warn!(
                parent_session_id = %parent_session_id,
                subagent_session_id = %subagent_session_id,
                wall_clock_timeout_ms,
                "conflict-resolver subagent exceeded wall-clock timeout and was cancelled"
            );
        }

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
        assert_eq!(FALLBACK_ALLOWED_TOOLS, &["Read", "Edit", "Write", "Bash"],);
        // Must NOT expose SpawnSubagent to prevent recursive resolver
        // spawning.
        assert!(!FALLBACK_ALLOWED_TOOLS.contains(&"SpawnSubagent"));
    }

    // ─── wait_or_cancel: wall-clock timeout tests (M9) ─────────────────

    use crate::tools::errors::ToolError;
    use crate::tools::traits::{JobInfo, SubagentResult};
    use async_trait::async_trait;

    /// Mock `SubagentOps` that either always times out or always succeeds
    /// on `wait_for_agents`, records every `cancel_subagent` call, and
    /// keeps every other method as a no-op (unused by the code under
    /// test).
    struct MockOps {
        should_timeout: parking_lot::Mutex<bool>,
        cancel_calls: parking_lot::Mutex<Vec<String>>,
        waits: parking_lot::Mutex<Vec<u64>>,
    }

    impl MockOps {
        fn timing_out() -> Self {
            Self {
                should_timeout: parking_lot::Mutex::new(true),
                cancel_calls: parking_lot::Mutex::new(Vec::new()),
                waits: parking_lot::Mutex::new(Vec::new()),
            }
        }
        fn succeeding() -> Self {
            Self {
                should_timeout: parking_lot::Mutex::new(false),
                cancel_calls: parking_lot::Mutex::new(Vec::new()),
                waits: parking_lot::Mutex::new(Vec::new()),
            }
        }
        fn cancel_calls(&self) -> Vec<String> {
            self.cancel_calls.lock().clone()
        }
        fn waits(&self) -> Vec<u64> {
            self.waits.lock().clone()
        }
    }

    #[async_trait]
    impl SubagentOps for MockOps {
        fn list_active_jobs(&self, _parent_session_id: &str) -> Vec<JobInfo> {
            Vec::new()
        }
        fn cancel_subagent(&self, session_id: &str) -> Result<(), ToolError> {
            self.cancel_calls.lock().push(session_id.to_owned());
            // After cancel, flip the behavior so the drain wait succeeds
            // promptly — simulates the subagent unwinding in response to
            // the cancel token.
            *self.should_timeout.lock() = false;
            Ok(())
        }
        async fn wait_for_agents(
            &self,
            session_ids: &[String],
            _mode: WaitMode,
            timeout_ms: u64,
        ) -> Result<Vec<SubagentResult>, ToolError> {
            self.waits.lock().push(timeout_ms);
            if *self.should_timeout.lock() {
                // Sleep a tick so the test wall-clock advances a little
                // (keeps the timing ordering realistic without waiting
                // the full `timeout_ms`).
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                return Err(ToolError::Timeout { timeout_ms });
            }
            Ok(session_ids
                .iter()
                .map(|sid| SubagentResult {
                    session_id: sid.clone(),
                    output: String::new(),
                    token_usage: None,
                    duration_ms: 0,
                    status: "completed".into(),
                    turns_executed: 0,
                })
                .collect())
        }
        fn get_subagent_result(&self, _session_id: &str) -> Option<SubagentResult> {
            None
        }
    }

    #[tokio::test]
    async fn timeout_interrupts_long_running_resolver() {
        // *** M9 regression test. ***
        //
        // Before the fix, the watcher had a hardcoded 30-minute wait and
        // never called cancel on timeout — a runaway resolver could keep
        // spending turns until its own `max_turns` ran out. This test
        // pins the new contract: on wall-clock timeout, the subagent is
        // cancelled, and only then does the function return.
        let mock = MockOps::timing_out();
        let completed = wait_or_cancel(&mock, "sess-resolver", 50).await;

        assert!(
            !completed,
            "expected wait_or_cancel to report not-completed on timeout"
        );
        assert_eq!(
            mock.cancel_calls(),
            vec!["sess-resolver".to_string()],
            "subagent must be cancelled exactly once on timeout"
        );
        // Two waits: one with the wall-clock bound, one drain with
        // `CANCEL_DRAIN_MS`. Both must target the same session.
        let waits = mock.waits();
        assert_eq!(waits.len(), 2);
        assert_eq!(waits[0], 50, "first wait uses wall_clock_timeout_ms");
        assert_eq!(waits[1], CANCEL_DRAIN_MS, "second wait is the drain");
    }

    #[tokio::test]
    async fn fast_resolver_does_not_cancel() {
        // The subagent finished before the wall clock fired — cancel
        // must NOT be called, and there must be exactly one wait.
        let mock = MockOps::succeeding();
        let completed = wait_or_cancel(&mock, "sess-ok", 5_000).await;

        assert!(completed, "expected wait_or_cancel to report completion");
        assert!(
            mock.cancel_calls().is_empty(),
            "cancel must not be called on clean completion"
        );
        assert_eq!(mock.waits(), vec![5_000]);
    }

    #[tokio::test]
    async fn drain_runs_even_when_cancel_fails() {
        // Defensive: even if cancel_subagent returns an error (e.g. the
        // subagent already completed between timeout and cancel), the
        // drain wait must still run so a completed-but-not-yet-observed
        // tracker can settle.
        struct FailingCancelOps {
            inner: MockOps,
        }
        #[async_trait]
        impl SubagentOps for FailingCancelOps {
            fn list_active_jobs(&self, _: &str) -> Vec<JobInfo> {
                Vec::new()
            }
            fn cancel_subagent(&self, _: &str) -> Result<(), ToolError> {
                Err(ToolError::Validation {
                    message: "not found".into(),
                })
            }
            async fn wait_for_agents(
                &self,
                session_ids: &[String],
                mode: WaitMode,
                timeout_ms: u64,
            ) -> Result<Vec<SubagentResult>, ToolError> {
                self.inner
                    .wait_for_agents(session_ids, mode, timeout_ms)
                    .await
            }
            fn get_subagent_result(&self, _: &str) -> Option<SubagentResult> {
                None
            }
        }
        let mock = FailingCancelOps {
            inner: MockOps::timing_out(),
        };
        let completed = wait_or_cancel(&mock, "sess-x", 20).await;
        assert!(!completed);
        // Both waits still happened — the first with the wall-clock
        // bound, the second the drain.
        let waits = mock.inner.waits();
        assert_eq!(waits.len(), 2);
        assert_eq!(waits[0], 20);
        assert_eq!(waits[1], CANCEL_DRAIN_MS);
    }
}
