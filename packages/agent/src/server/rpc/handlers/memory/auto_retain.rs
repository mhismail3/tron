//! Automatic memory retention policy.
//!
//! Decides whether to fire the retain pipeline at the end of an agent run,
//! based on `memory.autoRetainInterval` from settings and the session's turn
//! history. Three layers, each independently testable:
//!
//! - [`should_auto_retain`] — pure policy decision, no I/O.
//! - [`gather_state`] — sync state read from the event store.
//! - [`maybe_fire`] — async entry point called from `agent_prompt_service`.

use tracing::{debug, warn};

use crate::events::EventStore;
use crate::events::types::payloads::memory::MemoryRetainedPayload;
use crate::server::rpc::context::run_blocking_task;
use crate::server::rpc::errors::{RpcError, SESSION_NOT_FOUND};
use crate::server::rpc::handlers::map_event_store_error;

use super::RetainDeps;

/// Inputs to the auto-retain policy. Pure data; no I/O required to build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AutoRetainInput {
    /// `memory.auto_retain_interval` from settings. `0` disables auto-retain.
    pub interval: u32,
    /// Current `turn_count` on the session (MessageAssistant events logged).
    pub current_turn_count: i64,
    /// `turn_number` of the most recent `memory.retained` event, or `0` if none.
    pub last_retained_turn: i64,
    /// True if this session has a `parent_session_id` — i.e., it's a subagent
    /// run. Auto-retain never fires for subagents.
    pub is_subagent: bool,
}

/// Outcome of the policy. `Fire` carries `interval_fired` for the event payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoRetainDecision {
    Fire { interval_fired: u32 },
    Skip(SkipReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// `interval == 0`.
    Disabled,
    /// Session belongs to a subagent.
    Subagent,
    /// Session hasn't produced any assistant turns yet (`current_turn_count == 0`).
    NoPriorTurns,
    /// `current_turn_count - last_retained_turn < interval`.
    BelowThreshold,
}

/// Pure policy decision. No I/O.
///
/// Threshold math: fire when `current - last_retained >= interval`. This
/// correctly handles interval changes mid-session — e.g., if the interval
/// moves from 5 to 10 after a retain at turn 5, the next fire happens at
/// turn 15 (not turn 10).
pub fn should_auto_retain(input: AutoRetainInput) -> AutoRetainDecision {
    if input.is_subagent {
        return AutoRetainDecision::Skip(SkipReason::Subagent);
    }
    if input.interval == 0 {
        return AutoRetainDecision::Skip(SkipReason::Disabled);
    }
    if input.current_turn_count <= 0 {
        return AutoRetainDecision::Skip(SkipReason::NoPriorTurns);
    }
    let delta = input.current_turn_count - input.last_retained_turn;
    if delta >= i64::from(input.interval) {
        AutoRetainDecision::Fire {
            interval_fired: input.interval,
        }
    } else {
        AutoRetainDecision::Skip(SkipReason::BelowThreshold)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// State gathering (sync, testable)
// ─────────────────────────────────────────────────────────────────────────────

/// Read the event store to build the inputs for [`should_auto_retain`].
///
/// Blocking: hits SQLite. Must be called from a blocking context
/// (e.g. wrapped in `run_blocking` from an async caller).
pub fn gather_state(
    event_store: &EventStore,
    session_id: &str,
    interval: u32,
) -> Result<AutoRetainInput, RpcError> {
    let session = event_store
        .get_session(session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| RpcError::NotFound {
            code: SESSION_NOT_FOUND.into(),
            message: format!("session {session_id} not found"),
        })?;

    let last_retained_turn = match event_store
        .get_latest_event_by_type(session_id, "memory.retained")
        .map_err(map_event_store_error)?
    {
        Some(row) => {
            let payload: MemoryRetainedPayload =
                serde_json::from_str(&row.payload).map_err(|e| RpcError::Internal {
                    message: format!("memory.retained payload: {e}"),
                })?;
            payload.turn_number
        }
        None => 0,
    };

    Ok(AutoRetainInput {
        interval,
        current_turn_count: session.turn_count,
        last_retained_turn,
        is_subagent: session.parent_session_id.is_some(),
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Async entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Evaluate auto-retain policy and fire `trigger_retain` if the threshold is
/// crossed. Fire-and-forget from the caller's perspective — errors are logged
/// but never surfaced upward.
///
/// Reads the current `memory.auto_retain_interval` from the settings singleton.
/// The setting is hot-reloadable via `settings.update` RPC, so user changes
/// take effect on the next agent run without a server restart.
pub async fn maybe_fire(deps: &RetainDeps, session_id: &str) {
    let interval = crate::settings::get_settings().memory.auto_retain_interval;
    maybe_fire_with_interval(deps, session_id, interval).await;
}

/// Core of [`maybe_fire`] with the threshold passed in explicitly. Exists so
/// tests can exercise the full `gather_state` → `should_auto_retain` →
/// `trigger_retain` composition without mutating the global settings singleton.
async fn maybe_fire_with_interval(deps: &RetainDeps, session_id: &str, interval: u32) {
    // Cheap short-circuit: avoid hitting SQLite when auto-retain is disabled.
    if interval == 0 {
        return;
    }

    let event_store = deps.event_store.clone();
    let session_id_owned = session_id.to_owned();
    let session_id_for_task = session_id_owned.clone();
    let gather_result = run_blocking_task("memory.auto_retain.gather_state", move || {
        gather_state(&event_store, &session_id_for_task, interval)
    })
    .await;

    let input = match gather_result {
        Ok(input) => input,
        Err(err) => {
            warn!(
                session_id = %session_id_owned,
                error = %err,
                "auto-retain: failed to gather state; skipping"
            );
            return;
        }
    };

    match should_auto_retain(input) {
        AutoRetainDecision::Fire { interval_fired } => {
            debug!(
                session_id = %session_id_owned,
                interval_fired,
                current_turn = input.current_turn_count,
                last_retained_turn = input.last_retained_turn,
                "auto-retain: firing"
            );
            if let Err(err) = super::trigger_retain(
                deps,
                session_id_owned.clone(),
                super::RetainSource::Auto { interval_fired },
            )
            .await
            {
                warn!(
                    session_id = %session_id_owned,
                    error = %err,
                    "auto-retain: trigger_retain failed"
                );
            }
        }
        AutoRetainDecision::Skip(reason) => {
            debug!(
                session_id = %session_id_owned,
                ?reason,
                current_turn = input.current_turn_count,
                last_retained_turn = input.last_retained_turn,
                interval,
                "auto-retain: skipped"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn input(
        interval: u32,
        current: i64,
        last_retained: i64,
        is_subagent: bool,
    ) -> AutoRetainInput {
        AutoRetainInput {
            interval,
            current_turn_count: current,
            last_retained_turn: last_retained,
            is_subagent,
        }
    }

    #[test]
    fn should_auto_retain_table() {
        // (interval, current, last_retained, is_subagent, expected)
        let cases: &[(u32, i64, i64, bool, AutoRetainDecision)] = &[
            // disabled via interval=0 takes precedence over threshold
            (0, 100, 0, false, AutoRetainDecision::Skip(SkipReason::Disabled)),
            // subagent guard is highest priority
            (5, 100, 0, true, AutoRetainDecision::Skip(SkipReason::Subagent)),
            (0, 100, 0, true, AutoRetainDecision::Skip(SkipReason::Subagent)),
            // no prior turns
            (5, 0, 0, false, AutoRetainDecision::Skip(SkipReason::NoPriorTurns)),
            // below threshold from start
            (5, 4, 0, false, AutoRetainDecision::Skip(SkipReason::BelowThreshold)),
            // exactly threshold from start
            (5, 5, 0, false, AutoRetainDecision::Fire { interval_fired: 5 }),
            // past threshold with a prior retain
            (5, 10, 5, false, AutoRetainDecision::Fire { interval_fired: 5 }),
            // below threshold after a prior retain
            (5, 9, 5, false, AutoRetainDecision::Skip(SkipReason::BelowThreshold)),
            // interval change mid-session: 5→10 after retain at 5; turn 10 should NOT fire
            (10, 10, 5, false, AutoRetainDecision::Skip(SkipReason::BelowThreshold)),
            // same scenario at turn 15: fires
            (10, 15, 5, false, AutoRetainDecision::Fire { interval_fired: 10 }),
            // far past threshold
            (5, 100, 0, false, AutoRetainDecision::Fire { interval_fired: 5 }),
            // interval_fired reports the interval that triggered the fire
            (7, 14, 7, false, AutoRetainDecision::Fire { interval_fired: 7 }),
        ];

        for (i, (interval, current, last_retained, is_subagent, expected)) in
            cases.iter().enumerate()
        {
            let got = should_auto_retain(input(*interval, *current, *last_retained, *is_subagent));
            assert_eq!(
                got, *expected,
                "case {i}: interval={interval} current={current} last_retained={last_retained} is_subagent={is_subagent}",
            );
        }
    }

    #[test]
    fn fire_carries_interval_not_delta() {
        let got = should_auto_retain(input(3, 100, 0, false));
        assert_eq!(got, AutoRetainDecision::Fire { interval_fired: 3 });
    }

    #[test]
    fn subagent_skip_takes_precedence_over_threshold() {
        let got = should_auto_retain(input(1, 10, 0, true));
        assert_eq!(got, AutoRetainDecision::Skip(SkipReason::Subagent));
    }

    #[test]
    fn disabled_skip_takes_precedence_over_threshold() {
        let got = should_auto_retain(input(0, 10, 0, false));
        assert_eq!(got, AutoRetainDecision::Skip(SkipReason::Disabled));
    }

    #[test]
    fn no_prior_turns_even_when_last_retained_nonzero() {
        // Pathological but defensible: if the event store is in a weird state
        // and current_turn_count is 0, we never fire regardless of last_retained.
        let got = should_auto_retain(input(5, 0, 3, false));
        assert_eq!(got, AutoRetainDecision::Skip(SkipReason::NoPriorTurns));
    }

    // ─── gather_state (integration with in-memory event store) ─────────────

    use crate::events::{AppendOptions, EventStore, EventType};
    use std::sync::Arc;

    fn test_store() -> Arc<EventStore> {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default())
            .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    fn seed_session(store: &EventStore, parent: Option<&str>) -> String {
        match parent {
            None => store
                .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
                .unwrap()
                .session
                .id,
            Some(parent_id) => {
                use crate::events::sqlite::repositories::session::{
                    CreateSessionOptions, SessionRepo,
                };
                let ws = store.get_or_create_workspace("/tmp", None).unwrap();
                let conn = store.pool().get().unwrap();
                SessionRepo::create(
                    &conn,
                    &CreateSessionOptions {
                        workspace_id: &ws.id,
                        model: "claude-sonnet-4-6",
                        working_directory: "/tmp",
                        title: Some("subagent"),
                        tags: None,
                        parent_session_id: Some(parent_id),
                        fork_from_event_id: None,
                        spawning_session_id: Some(parent_id),
                        spawn_type: Some("tool"),
                        spawn_task: Some("test"),
                        origin: None,
                        source: None,
                        use_worktree: None,
                    },
                )
                .unwrap()
                .id
            }
        }
    }

    fn set_turn_count(store: &EventStore, session_id: &str, turn_count: i64) {
        use crate::events::sqlite::repositories::session::{IncrementCounters, SessionRepo};
        let conn = store.pool().get().unwrap();
        SessionRepo::increment_counters(
            &conn,
            session_id,
            &IncrementCounters {
                turn_count: Some(turn_count),
                ..Default::default()
            },
        )
        .unwrap();
    }

    fn append_memory_retained(store: &EventStore, session_id: &str, turn_number: i64) {
        let payload = serde_json::json!({
            "sessionId": session_id,
            "turnNumber": turn_number,
            "title": "Test",
            "summary": "Test summary",
            "timestamp": "2026-04-20T00:00:00Z",
        });
        store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MemoryRetained,
                payload,
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    #[test]
    fn gather_state_reads_turn_count_and_no_last_retained() {
        let store = test_store();
        let sid = seed_session(&store, None);
        set_turn_count(&store, &sid, 7);

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.interval, 5);
        assert_eq!(input.current_turn_count, 7);
        assert_eq!(input.last_retained_turn, 0);
        assert!(!input.is_subagent);
    }

    #[test]
    fn gather_state_reads_latest_memory_retained_turn_number() {
        let store = test_store();
        let sid = seed_session(&store, None);
        set_turn_count(&store, &sid, 15);
        append_memory_retained(&store, &sid, 5);
        append_memory_retained(&store, &sid, 10);

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.last_retained_turn, 10); // the most recent one
        assert_eq!(input.current_turn_count, 15);
    }

    #[test]
    fn gather_state_flags_subagent_when_parent_id_set() {
        let store = test_store();
        let parent = seed_session(&store, None);
        let child = seed_session(&store, Some(&parent));
        set_turn_count(&store, &child, 3);

        let input = gather_state(&store, &child, 5).unwrap();
        assert!(input.is_subagent, "child with parent should be flagged");

        let parent_input = gather_state(&store, &parent, 5).unwrap();
        assert!(!parent_input.is_subagent, "root session should not be");
    }

    #[test]
    fn gather_state_unknown_session_returns_not_found() {
        let store = test_store();
        let err = gather_state(&store, "sess_does_not_exist", 5).unwrap_err();
        assert_eq!(err.code(), SESSION_NOT_FOUND);
    }

    #[test]
    fn gather_state_passes_interval_through_unchanged() {
        let store = test_store();
        let sid = seed_session(&store, None);
        set_turn_count(&store, &sid, 1);
        let input = gather_state(&store, &sid, 42).unwrap();
        assert_eq!(input.interval, 42);
    }

    #[test]
    fn gather_state_composes_with_policy_to_fire() {
        let store = test_store();
        let sid = seed_session(&store, None);
        set_turn_count(&store, &sid, 5);

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(
            should_auto_retain(input),
            AutoRetainDecision::Fire { interval_fired: 5 }
        );
    }

    #[test]
    fn gather_state_composes_with_policy_to_skip_subagent() {
        let store = test_store();
        let parent = seed_session(&store, None);
        let child = seed_session(&store, Some(&parent));
        set_turn_count(&store, &child, 100);

        let input = gather_state(&store, &child, 5).unwrap();
        assert_eq!(
            should_auto_retain(input),
            AutoRetainDecision::Skip(SkipReason::Subagent)
        );
    }

    // ─── maybe_fire_with_interval end-to-end ───────────────────────────────

    use crate::server::rpc::handlers::test_helpers::make_test_context;

    fn deps_from_ctx(
        ctx: &crate::server::rpc::context::RpcContext,
    ) -> crate::server::rpc::handlers::memory::RetainDeps {
        crate::server::rpc::handlers::memory::RetainDeps::from_rpc(ctx)
    }

    #[tokio::test]
    async fn maybe_fire_with_interval_persists_trigger_when_threshold_crossed() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        set_turn_count(&ctx.event_store, &sid, 3);

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 3).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap()
            .expect("threshold crossed: trigger event must be persisted");
        let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
        assert_eq!(payload["intervalFired"], 3);
        assert_eq!(payload["turnNumber"], 3);
    }

    #[tokio::test]
    async fn maybe_fire_with_interval_skips_below_threshold() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        set_turn_count(&ctx.event_store, &sid, 2);

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 5).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(row.is_none(), "below threshold: no trigger event expected");
    }

    #[tokio::test]
    async fn maybe_fire_with_interval_zero_is_disabled() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        set_turn_count(&ctx.event_store, &sid, 100);

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 0).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(row.is_none(), "interval=0: auto-retain must be disabled");
    }

    #[tokio::test]
    async fn maybe_fire_with_interval_skips_subagent() {
        let ctx = make_test_context();
        let parent_id = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap()
            .session
            .id;
        // Seed a subagent session whose parent is set.
        let child = seed_session(&ctx.event_store, Some(&parent_id));
        set_turn_count(&ctx.event_store, &child, 100);

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &child, 5).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&child, "memory.auto_retain_triggered")
            .unwrap();
        assert!(
            row.is_none(),
            "subagent sessions must never auto-retain (parent_session_id is_some)"
        );
    }

    #[tokio::test]
    async fn maybe_fire_with_interval_respects_prior_retain_boundary() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();

        // Simulate a prior retain at turn 5 and a current turn of 8.
        set_turn_count(&ctx.event_store, &sid, 8);
        append_memory_retained(&ctx.event_store, &sid, 5);

        let deps = deps_from_ctx(&ctx);
        // Interval of 5 → delta is 8-5=3, below threshold → no fire.
        maybe_fire_with_interval(&deps, &sid, 5).await;
        assert!(
            ctx.event_store
                .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
                .unwrap()
                .is_none(),
            "8-5 < 5: must not fire"
        );

        // Bump to turn 10 — delta is 10-5=5, threshold met.
        set_turn_count(&ctx.event_store, &sid, 2); // +2 more (total 10)
        maybe_fire_with_interval(&deps, &sid, 5).await;
        assert!(
            ctx.event_store
                .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
                .unwrap()
                .is_some(),
            "10-5 >= 5: must fire"
        );
    }
}
