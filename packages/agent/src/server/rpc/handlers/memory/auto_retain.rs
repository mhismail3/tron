//! Automatic memory retention policy.
//!
//! Decides whether to fire the retain pipeline at the end of an agent run,
//! based on `memory.autoRetainInterval` from settings and the session's
//! **user-message** history. The threshold unit is a user-visible exchange,
//! not an agent internal turn — a single prompt that spawns ten tool calls
//! counts as one toward the threshold.
//!
//! Three layers, each independently testable:
//! - [`should_auto_retain`] — pure policy decision, no I/O.
//! - [`gather_state`] — sync state read from the event store.
//! - [`maybe_fire`] — async entry point called from `agent_prompt_service`.

use tracing::{debug, warn};

use crate::events::EventStore;
use crate::server::rpc::context::run_blocking_task;
use crate::server::rpc::errors::{RpcError, SESSION_NOT_FOUND};
use crate::server::rpc::handlers::map_event_store_error;

use super::RetainDeps;

/// Event type string for user-message events. Single source of truth.
const USER_MESSAGE_TYPE: &str = "message.user";

/// Event type string for the retain-boundary event.
const RETAINED_TYPE: &str = "memory.retained";

/// Inputs to the auto-retain policy. Pure data; no I/O required to build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AutoRetainInput {
    /// `memory.auto_retain_interval` from settings. `0` disables auto-retain.
    pub interval: u32,
    /// Number of `message.user` events appended to the session **since** the
    /// most recent `memory.retained` event (or session start, whichever is
    /// later).
    pub user_messages_since_retain: i64,
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
    /// No user-visible exchanges since the last retain (`user_messages_since_retain == 0`).
    NoUserMessages,
    /// `user_messages_since_retain < interval`.
    BelowThreshold,
}

/// Pure policy decision. No I/O.
///
/// Threshold: fire when `user_messages_since_retain >= interval`. The input is
/// already a delta (user messages since the last retain boundary), so the
/// comparison is direct — no subtraction or boundary arithmetic inside the
/// policy.
pub fn should_auto_retain(input: AutoRetainInput) -> AutoRetainDecision {
    if input.is_subagent {
        return AutoRetainDecision::Skip(SkipReason::Subagent);
    }
    if input.interval == 0 {
        return AutoRetainDecision::Skip(SkipReason::Disabled);
    }
    if input.user_messages_since_retain <= 0 {
        return AutoRetainDecision::Skip(SkipReason::NoUserMessages);
    }
    if input.user_messages_since_retain >= i64::from(input.interval) {
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
///
/// The "since last retain" count is derived from the sequence of the most
/// recent `memory.retained` event (0 if none) — the retain event itself is
/// the boundary, so no `turn_number` field needs to live on its payload.
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

    let last_retained_sequence = event_store
        .get_latest_event_by_type(session_id, RETAINED_TYPE)
        .map_err(map_event_store_error)?
        .map(|row| row.sequence)
        .unwrap_or(0);

    let user_messages_since_retain = event_store
        .count_events_by_type_after_sequence(
            session_id,
            USER_MESSAGE_TYPE,
            last_retained_sequence,
        )
        .map_err(map_event_store_error)?;

    Ok(AutoRetainInput {
        interval,
        user_messages_since_retain,
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
                user_messages_since_retain = input.user_messages_since_retain,
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
                user_messages_since_retain = input.user_messages_since_retain,
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

    fn input(interval: u32, user_msgs: i64, is_subagent: bool) -> AutoRetainInput {
        AutoRetainInput {
            interval,
            user_messages_since_retain: user_msgs,
            is_subagent,
        }
    }

    #[test]
    fn should_auto_retain_table() {
        // (interval, user_messages_since_retain, is_subagent, expected)
        let cases: &[(u32, i64, bool, AutoRetainDecision)] = &[
            // subagent guard is highest priority, regardless of threshold
            (5, 100, true, AutoRetainDecision::Skip(SkipReason::Subagent)),
            (0, 100, true, AutoRetainDecision::Skip(SkipReason::Subagent)),
            // disabled via interval=0
            (0, 100, false, AutoRetainDecision::Skip(SkipReason::Disabled)),
            // no user messages since last retain
            (5, 0, false, AutoRetainDecision::Skip(SkipReason::NoUserMessages)),
            // below threshold
            (5, 4, false, AutoRetainDecision::Skip(SkipReason::BelowThreshold)),
            // exactly threshold
            (5, 5, false, AutoRetainDecision::Fire { interval_fired: 5 }),
            // past threshold
            (5, 10, false, AutoRetainDecision::Fire { interval_fired: 5 }),
            // small interval of 2 (the user's common case)
            (2, 1, false, AutoRetainDecision::Skip(SkipReason::BelowThreshold)),
            (2, 2, false, AutoRetainDecision::Fire { interval_fired: 2 }),
            (2, 3, false, AutoRetainDecision::Fire { interval_fired: 2 }),
            // interval of 1 fires on the very first user message
            (1, 1, false, AutoRetainDecision::Fire { interval_fired: 1 }),
            // interval_fired reports the interval that triggered the fire, not the delta
            (7, 14, false, AutoRetainDecision::Fire { interval_fired: 7 }),
            // negative / pathological count treated as "nothing to retain"
            (5, -1, false, AutoRetainDecision::Skip(SkipReason::NoUserMessages)),
        ];

        for (i, (interval, user_msgs, is_subagent, expected)) in cases.iter().enumerate() {
            let got = should_auto_retain(input(*interval, *user_msgs, *is_subagent));
            assert_eq!(
                got, *expected,
                "case {i}: interval={interval} user_msgs={user_msgs} is_subagent={is_subagent}",
            );
        }
    }

    #[test]
    fn fire_carries_interval_not_delta() {
        // The fire payload must carry `interval` (the policy knob), not the
        // delta (number of messages observed). Otherwise logs / iOS labels
        // would flicker based on how often the agent gets invoked.
        let got = should_auto_retain(input(3, 100, false));
        assert_eq!(got, AutoRetainDecision::Fire { interval_fired: 3 });
    }

    #[test]
    fn subagent_skip_takes_precedence_over_threshold() {
        let got = should_auto_retain(input(1, 10, true));
        assert_eq!(got, AutoRetainDecision::Skip(SkipReason::Subagent));
    }

    #[test]
    fn disabled_skip_takes_precedence_over_below_threshold() {
        let got = should_auto_retain(input(0, 10, false));
        assert_eq!(got, AutoRetainDecision::Skip(SkipReason::Disabled));
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

    /// Append a `message.user` event. Returns the persisted event's sequence.
    fn append_user_message(store: &EventStore, session_id: &str, text: &str) -> i64 {
        store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({ "content": text }),
                parent_id: None,
                sequence: None,
            })
            .unwrap()
            .sequence
    }

    /// Append a `memory.retained` boundary event. No `turn_number` field —
    /// the sequence of the row is the boundary.
    fn append_memory_retained(store: &EventStore, session_id: &str) -> i64 {
        store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MemoryRetained,
                payload: serde_json::json!({
                    "sessionId": session_id,
                    "title": "Test",
                    "summary": "Test summary",
                    "timestamp": "2026-04-20T00:00:00Z",
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap()
            .sequence
    }

    #[test]
    fn gather_state_counts_zero_for_empty_session() {
        let store = test_store();
        let sid = seed_session(&store, None);

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.interval, 5);
        assert_eq!(input.user_messages_since_retain, 0);
        assert!(!input.is_subagent);
    }

    #[test]
    fn gather_state_counts_all_user_messages_when_no_prior_retain() {
        let store = test_store();
        let sid = seed_session(&store, None);

        append_user_message(&store, &sid, "first");
        append_user_message(&store, &sid, "second");
        append_user_message(&store, &sid, "third");

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.user_messages_since_retain, 3);
    }

    #[test]
    fn gather_state_counts_only_user_messages_after_latest_retain() {
        let store = test_store();
        let sid = seed_session(&store, None);

        // Before retain: 3 user messages.
        append_user_message(&store, &sid, "a");
        append_user_message(&store, &sid, "b");
        append_user_message(&store, &sid, "c");
        append_memory_retained(&store, &sid);
        // After retain: 2 more.
        append_user_message(&store, &sid, "d");
        append_user_message(&store, &sid, "e");

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(
            input.user_messages_since_retain, 2,
            "only messages after the retain boundary count"
        );
    }

    #[test]
    fn gather_state_boundary_uses_latest_retain_when_multiple() {
        let store = test_store();
        let sid = seed_session(&store, None);

        append_user_message(&store, &sid, "a");
        append_memory_retained(&store, &sid); // first retain
        append_user_message(&store, &sid, "b");
        append_user_message(&store, &sid, "c");
        append_memory_retained(&store, &sid); // second retain — this one is the boundary
        append_user_message(&store, &sid, "d");

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.user_messages_since_retain, 1);
    }

    #[test]
    fn gather_state_counts_user_messages_not_assistant() {
        // Assistant events and other types must not pollute the count.
        let store = test_store();
        let sid = seed_session(&store, None);

        append_user_message(&store, &sid, "u1");
        // Append an assistant event — should NOT be counted.
        store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({ "content": "reply" }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        append_user_message(&store, &sid, "u2");

        let input = gather_state(&store, &sid, 5).unwrap();
        assert_eq!(input.user_messages_since_retain, 2);
    }

    #[test]
    fn gather_state_flags_subagent_when_parent_id_set() {
        let store = test_store();
        let parent = seed_session(&store, None);
        let child = seed_session(&store, Some(&parent));
        append_user_message(&store, &child, "task prompt");

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
        append_user_message(&store, &sid, "msg");
        let input = gather_state(&store, &sid, 42).unwrap();
        assert_eq!(input.interval, 42);
    }

    #[test]
    fn gather_state_composes_with_policy_to_fire() {
        let store = test_store();
        let sid = seed_session(&store, None);
        append_user_message(&store, &sid, "a");
        append_user_message(&store, &sid, "b");

        let input = gather_state(&store, &sid, 2).unwrap();
        assert_eq!(
            should_auto_retain(input),
            AutoRetainDecision::Fire { interval_fired: 2 }
        );
    }

    #[test]
    fn gather_state_composes_with_policy_to_skip_subagent() {
        let store = test_store();
        let parent = seed_session(&store, None);
        let child = seed_session(&store, Some(&parent));
        for _ in 0..100 {
            append_user_message(&store, &child, "prompt");
        }

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
    async fn maybe_fire_persists_trigger_when_threshold_crossed() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        // 3 user messages, interval 3 → fires.
        append_user_message(&ctx.event_store, &sid, "a");
        append_user_message(&ctx.event_store, &sid, "b");
        append_user_message(&ctx.event_store, &sid, "c");

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 3).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap()
            .expect("threshold crossed: trigger event must be persisted");
        let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
        assert_eq!(payload["intervalFired"], 3);
    }

    #[tokio::test]
    async fn maybe_fire_skips_below_threshold() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        // 2 user messages, interval 5 → skip.
        append_user_message(&ctx.event_store, &sid, "a");
        append_user_message(&ctx.event_store, &sid, "b");

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 5).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(row.is_none(), "below threshold: no trigger event expected");
    }

    #[tokio::test]
    async fn maybe_fire_zero_is_disabled() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();
        for _ in 0..10 {
            append_user_message(&ctx.event_store, &sid, "x");
        }

        let deps = deps_from_ctx(&ctx);
        maybe_fire_with_interval(&deps, &sid, 0).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(row.is_none(), "interval=0: auto-retain must be disabled");
    }

    #[tokio::test]
    async fn maybe_fire_skips_subagent() {
        let ctx = make_test_context();
        let parent_id = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap()
            .session
            .id;
        let child = seed_session(&ctx.event_store, Some(&parent_id));
        for _ in 0..100 {
            append_user_message(&ctx.event_store, &child, "task");
        }

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
    async fn maybe_fire_respects_prior_retain_boundary() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();

        // 5 user messages, then a retain → resets the boundary.
        for _ in 0..5 {
            append_user_message(&ctx.event_store, &sid, "pre");
        }
        append_memory_retained(&ctx.event_store, &sid);

        let deps = deps_from_ctx(&ctx);

        // 2 more user messages; interval 3 → should NOT fire.
        append_user_message(&ctx.event_store, &sid, "post-1");
        append_user_message(&ctx.event_store, &sid, "post-2");
        maybe_fire_with_interval(&deps, &sid, 3).await;
        assert!(
            ctx.event_store
                .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
                .unwrap()
                .is_none(),
            "2 messages since retain < interval 3: must not fire"
        );

        // 1 more (total 3 since retain) → fires.
        append_user_message(&ctx.event_store, &sid, "post-3");
        maybe_fire_with_interval(&deps, &sid, 3).await;
        assert!(
            ctx.event_store
                .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
                .unwrap()
                .is_some(),
            "3 messages since retain >= interval 3: must fire"
        );
    }

    /// Regression guard for the bug that prompted this refactor: a single
    /// user prompt that spawns many agent iterations (tool calls) must count
    /// as ONE toward the threshold, not N.
    #[tokio::test]
    async fn maybe_fire_counts_user_messages_not_agent_iterations() {
        let ctx = make_test_context();
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let sid = cr.session.id.clone();

        // One user prompt.
        append_user_message(&ctx.event_store, &sid, "research gold prices");

        // Simulate the agent making many internal iterations (tool calls):
        // 10 assistant events, 10 turn_start/turn_end pairs. None of these
        // are user exchanges — they must not count toward the threshold.
        for _ in 0..10 {
            ctx.event_store
                .append(&AppendOptions {
                    session_id: &sid,
                    event_type: EventType::StreamTurnStart,
                    payload: serde_json::json!({ "turn": 1 }),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
            ctx.event_store
                .append(&AppendOptions {
                    session_id: &sid,
                    event_type: EventType::MessageAssistant,
                    payload: serde_json::json!({ "content": "tool call" }),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
            ctx.event_store
                .append(&AppendOptions {
                    session_id: &sid,
                    event_type: EventType::StreamTurnEnd,
                    payload: serde_json::json!({ "turn": 1 }),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let deps = deps_from_ctx(&ctx);
        // Interval 2 — with the old buggy logic that counted turn iterations,
        // this would fire after 2 internal iterations. With the correct
        // user-message-based counter, it MUST NOT fire after a single prompt.
        maybe_fire_with_interval(&deps, &sid, 2).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(
            row.is_none(),
            "one user prompt with ten tool calls must not cross an interval=2 threshold"
        );

        // Send a second user message. Now we have 2 user exchanges — fires.
        append_user_message(&ctx.event_store, &sid, "next prompt");
        maybe_fire_with_interval(&deps, &sid, 2).await;

        let row = ctx
            .event_store
            .get_latest_event_by_type(&sid, "memory.auto_retain_triggered")
            .unwrap();
        assert!(
            row.is_some(),
            "after 2 user exchanges the trigger must fire"
        );
    }
}
