use super::*;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::{ModelResponder, ModelResponderFactory, ModelResponseError};
use crate::domains::session::event_store::{
    AppendOptions, ConnectionConfig, ConnectionPool, EventStore, EventType, ListEventsOptions,
    new_in_memory, run_migrations,
};
use crate::shared::protocol::events::TronEvent;
use crate::shared::server::errors::EVENT_STORE_FAILURE;
use crate::shared::server::failure::RUNTIME_PERSISTENCE_ERROR;

struct CountingFactory {
    create_calls: Arc<AtomicUsize>,
}

#[async_trait]
impl ModelResponderFactory for CountingFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        self.create_calls.fetch_add(1, Ordering::SeqCst);
        Err(ModelResponseError::other(
            "provider construction must not follow a pre-provider failure",
        ))
    }
}

struct PromptFailureHarness {
    pool: ConnectionPool,
    event_store: Arc<EventStore>,
    session_id: String,
    root_event_id: String,
    model: String,
    working_dir: String,
    create_calls: Arc<AtomicUsize>,
}

struct PromptFailureOutcome {
    orchestrator: Arc<Orchestrator>,
    events: tokio::sync::broadcast::Receiver<TronEvent>,
}

impl PromptFailureHarness {
    fn new() -> Self {
        let pool = new_in_memory(&ConnectionConfig {
            pool_size: 1,
            ..ConnectionConfig::default()
        })
        .expect("event pool");
        {
            let conn = pool.get().expect("event connection");
            run_migrations(&conn).expect("event migrations");
        }
        let event_store = Arc::new(EventStore::new(pool.clone()));
        let session = event_store
            .create_session("mock", "/tmp", Some("failure boundary"), None)
            .expect("session");

        Self {
            pool,
            event_store,
            session_id: session.session.id,
            root_event_id: session.root_event.id,
            model: session.session.latest_model,
            working_dir: session.session.working_directory,
            create_calls: Arc::new(AtomicUsize::new(0)),
        }
    }

    async fn execute(&self, run_id: &str) -> PromptFailureOutcome {
        let session_manager = Arc::new(SessionManager::new(self.event_store.clone()));
        let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
        let started_run = orchestrator
            .begin_run(&self.session_id, run_id)
            .expect("run guard");
        let events = orchestrator.subscribe();

        execute_prompt_run(PromptRunPlan {
            started_run,
            orchestrator: orchestrator.clone(),
            session_manager,
            responder_factory: Arc::new(CountingFactory {
                create_calls: self.create_calls.clone(),
            }),
            settings: crate::domains::settings::TronSettings::default(),
            event_store: self.event_store.clone(),
            shutdown_token: None,
            shutdown_coordinator: None,
            engine_host: crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
            server_origin: "localhost:9847".to_owned(),
            run_id: run_id.to_owned(),
            model: self.model.clone(),
            working_dir: self.working_dir.clone(),
            request: PromptRequest {
                session_id: self.session_id.clone(),
                prompt: "must preserve durable history".to_owned(),
                reasoning_level: None,
                attachments: None,
                engine_causality: None,
            },
        })
        .await;

        PromptFailureOutcome {
            orchestrator,
            events,
        }
    }

    fn assert_stopped_before_provider(&self, outcome: &PromptFailureOutcome) {
        assert_eq!(
            self.create_calls.load(Ordering::SeqCst),
            0,
            "provider construction must not start after a prerequisite fails"
        );
        assert!(!outcome.orchestrator.has_active_run(&self.session_id));
        assert!(
            outcome
                .orchestrator
                .get_compaction_handler(&self.session_id)
                .is_none(),
            "pre-provider failure must not leak a compaction handler"
        );
    }
}

fn terminal_error_code(events: &mut tokio::sync::broadcast::Receiver<TronEvent>) -> String {
    let terminal_error = std::iter::from_fn(|| events.try_recv().ok())
        .find(|event| event.event_type() == "error")
        .expect("the acknowledged run must terminate with a client-visible error");
    let TronEvent::Error { code, .. } = terminal_error else {
        panic!("terminal event must retain the canonical error payload");
    };
    code.expect("terminal error code")
}

#[tokio::test]
async fn user_message_persistence_failure_aborts_before_provider_construction() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch(
            "CREATE TRIGGER fail_user_message
             BEFORE INSERT ON events
             WHEN NEW.type = 'message.user'
             BEGIN
               SELECT RAISE(FAIL, 'forced user-message failure');
             END;",
        )
        .expect("failure trigger");
    }

    let mut outcome = harness.execute("run-persist-failure").await;

    harness.assert_stopped_before_provider(&outcome);
    let rows = harness
        .event_store
        .get_events_by_session(&harness.session_id, &ListEventsOptions::default())
        .expect("session events");
    assert!(rows.iter().all(|row| row.event_type != "message.user"));
    assert!(
        rows.iter()
            .all(|row| row.event_type != "model.provider_request")
    );
    assert!(rows.iter().all(|row| row.event_type != "message.assistant"));
    let terminal_events = std::iter::from_fn(|| outcome.events.try_recv().ok()).collect::<Vec<_>>();
    assert_eq!(
        terminal_events
            .iter()
            .map(TronEvent::event_type)
            .collect::<Vec<_>>(),
        vec![
            "agent_end",
            "error",
            "session_processing_changed",
            "agent_ready",
        ]
    );
    let TronEvent::Error { code, .. } = &terminal_events[1] else {
        panic!("second terminal event must be the canonical failure");
    };
    assert_eq!(code.as_deref(), Some(EVENT_STORE_FAILURE));
    let replacement = outcome
        .orchestrator
        .begin_run(&harness.session_id, "run-after-persistence-failure")
        .expect("terminal boundary must immediately admit the replacement run");
    drop(replacement);
}

#[tokio::test]
async fn session_reconstruction_failure_never_substitutes_empty_history() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute(
            "UPDATE events SET timestamp = X'00' WHERE id = ?1",
            rusqlite::params![harness.root_event_id],
        )
        .expect("corrupt root timestamp type");
        let timestamp_type: String = conn
            .query_row(
                "SELECT typeof(timestamp) FROM events WHERE id = ?1",
                rusqlite::params![harness.root_event_id],
                |row| row.get(0),
            )
            .expect("root timestamp type");
        assert_eq!(timestamp_type, "blob");
    }

    let mut outcome = harness.execute("run-reconstruction-failure").await;

    harness.assert_stopped_before_provider(&outcome);
    let conn = harness.pool.get().expect("event connection");
    let event_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))
        .expect("event count");
    let user_message_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events WHERE type = 'message.user'",
            [],
            |row| row.get(0),
        )
        .expect("user-message count");
    assert_eq!(
        event_count, 1,
        "failed reconstruction must not append events"
    );
    assert_eq!(user_message_count, 0);
    assert_eq!(
        terminal_error_code(&mut outcome.events),
        RUNTIME_PERSISTENCE_ERROR
    );
}

#[tokio::test]
async fn unresolved_prior_capability_blocks_prompt_until_atomic_repair_commits() {
    let harness = PromptFailureHarness::new();
    for (event_type, payload) in [
        (EventType::StreamTurnStart, serde_json::json!({"turn": 1})),
        (
            EventType::MessageAssistant,
            serde_json::json!({
                "turn": 1,
                "content": [{
                    "type": "capability_invocation",
                    "id": "call-unresolved",
                    "name": "execute",
                    "arguments": {"operation": "observe"}
                }],
                "model": "mock",
                "stopReason": "capability_invocation"
            }),
        ),
        (
            EventType::CapabilityInvocationStarted,
            serde_json::json!({
                "turn": 1,
                "invocationId": "call-unresolved",
                "name": "execute",
                "arguments": {"operation": "observe"}
            }),
        ),
        (
            EventType::TurnFailed,
            serde_json::json!({
                "turn": 1,
                "error": "capability terminal persistence failed"
            }),
        ),
    ] {
        harness
            .event_store
            .append(&AppendOptions {
                session_id: &harness.session_id,
                event_type,
                payload,
                parent_id: None,
                sequence: None,
            })
            .expect("seed failed capability turn");
    }
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch(
            "CREATE TRIGGER reject_capability_repair
             BEFORE INSERT ON events
             WHEN NEW.type = 'capability.invocation.completed'
             BEGIN
               SELECT RAISE(FAIL, 'forced capability repair rejection');
             END;",
        )
        .expect("repair rejection trigger");
    }

    let mut blocked = harness.execute("run-blocked-by-prior-capability").await;

    harness.assert_stopped_before_provider(&blocked);
    let blocked_rows = harness
        .event_store
        .get_events_by_session(&harness.session_id, &ListEventsOptions::default())
        .expect("blocked session events");
    assert!(
        blocked_rows
            .iter()
            .all(|row| row.event_type != EventType::MessageUser.as_str()),
        "blocked admission must not persist the new user prompt"
    );
    assert!(
        blocked_rows
            .iter()
            .all(|row| { row.event_type != EventType::CapabilityInvocationCompleted.as_str() }),
        "failed repair must leave no partial terminal row"
    );
    assert_eq!(
        terminal_error_code(&mut blocked.events),
        RUNTIME_PERSISTENCE_ERROR
    );

    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch("DROP TRIGGER reject_capability_repair;")
            .expect("remove repair rejection");
    }
    let mut admitted = harness.execute("run-after-capability-repair").await;

    assert_eq!(
        harness.create_calls.load(Ordering::SeqCst),
        1,
        "provider construction starts only after repair commits"
    );
    assert!(!admitted.orchestrator.has_active_run(&harness.session_id));
    let repaired_rows = harness
        .event_store
        .get_events_by_session(&harness.session_id, &ListEventsOptions::default())
        .expect("repaired session events");
    assert_eq!(
        repaired_rows
            .iter()
            .filter(|row| row.event_type == EventType::MessageUser.as_str())
            .count(),
        1,
        "only the admitted retry persists its user prompt"
    );
    let repaired = repaired_rows
        .iter()
        .find(|row| {
            row.event_type == EventType::CapabilityInvocationCompleted.as_str()
                && row.invocation_id.as_deref() == Some("call-unresolved")
        })
        .expect("durable repaired capability completion");
    let live_repair = std::iter::from_fn(|| admitted.events.try_recv().ok())
        .find_map(|event| match event {
            TronEvent::CapabilityInvocationCompleted {
                base,
                invocation_id,
                result,
                ..
            } if invocation_id == "call-unresolved" => Some((base, result)),
            _ => None,
        })
        .expect("live row-backed repair completion");
    assert_eq!(live_repair.0.sequence, Some(repaired.sequence));
    let live_details = live_repair
        .1
        .and_then(|result| result.details)
        .expect("repair safety details");
    assert_eq!(live_details["executionState"], "unknown");
    assert_eq!(live_details["mayHaveExecuted"], true);
    assert_eq!(live_details["retrySafe"], false);
}

#[tokio::test]
async fn sequence_high_water_failure_stops_before_provider_construction() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch(
            "CREATE TRIGGER corrupt_sequence_after_user
             AFTER INSERT ON events
             WHEN NEW.type = 'message.user'
             BEGIN
               UPDATE events SET sequence = X'00' WHERE type = 'session.start';
             END;",
        )
        .expect("corruption trigger");
    }

    let mut outcome = harness.execute("run-sequence-read-failure").await;

    harness.assert_stopped_before_provider(&outcome);
    let conn = harness.pool.get().expect("event connection");
    let provider_request_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events WHERE type = 'model.provider_request'",
            [],
            |row| row.get(0),
        )
        .expect("provider request count");
    assert_eq!(provider_request_count, 0);
    assert_eq!(
        terminal_error_code(&mut outcome.events),
        RUNTIME_PERSISTENCE_ERROR
    );
}

#[tokio::test]
async fn exhausted_sequence_stops_before_provider_construction() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute(
            "UPDATE events SET sequence = ?1 WHERE id = ?2",
            rusqlite::params![i64::MAX - 1, harness.root_event_id],
        )
        .expect("seed final available user-message sequence");
    }

    let mut outcome = harness.execute("run-sequence-exhausted").await;

    harness.assert_stopped_before_provider(&outcome);
    let conn = harness.pool.get().expect("event connection");
    let user_sequence: i64 = conn
        .query_row(
            "SELECT sequence FROM events WHERE type = 'message.user'",
            [],
            |row| row.get(0),
        )
        .expect("durable user message");
    assert_eq!(user_sequence, i64::MAX);
    assert_eq!(
        terminal_error_code(&mut outcome.events),
        RUNTIME_PERSISTENCE_ERROR
    );
}

#[test]
fn failed_started_turn_advances_the_next_prompt_offset() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute(
            "UPDATE sessions SET turn_count = 19 WHERE id = ?1",
            rusqlite::params![harness.session_id],
        )
        .expect("seed completed turn count");
    }
    harness
        .event_store
        .append(&AppendOptions {
            session_id: &harness.session_id,
            event_type: EventType::StreamTurnStart,
            payload: serde_json::json!({"turn": 20}),
            parent_id: None,
            sequence: None,
        })
        .expect("persist turn start");
    harness
        .event_store
        .append(&AppendOptions {
            session_id: &harness.session_id,
            event_type: EventType::TurnFailed,
            payload: serde_json::json!({"turn": 20, "error": "cancelled"}),
            parent_id: None,
            sequence: None,
        })
        .expect("persist turn failure");

    let offset = resolve_turn_offset(&harness.event_store, &harness.session_id, 19).unwrap();
    assert_eq!(offset, 20);
    assert_eq!(offset.saturating_add(1), 21);
}

#[test]
fn turn_high_water_read_failure_is_not_downgraded() {
    let harness = PromptFailureHarness::new();
    harness
        .event_store
        .append(&AppendOptions {
            session_id: &harness.session_id,
            event_type: EventType::StreamTurnStart,
            payload: serde_json::json!({"turn": 20}),
            parent_id: None,
            sequence: None,
        })
        .expect("persist turn start");
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute(
            "UPDATE events SET turn = X'00' WHERE type = 'stream.turn_start'",
            [],
        )
        .expect("corrupt denormalized turn");
    }

    let error = resolve_turn_offset(&harness.event_store, &harness.session_id, 19).unwrap_err();
    assert!(matches!(
        error,
        crate::domains::agent::r#loop::errors::RuntimeError::Persistence(_)
    ));
}

#[test]
fn exhausted_turn_high_water_is_rejected() {
    let harness = PromptFailureHarness::new();
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute(
            "UPDATE sessions SET turn_count = ?1 WHERE id = ?2",
            rusqlite::params![i64::from(u32::MAX), harness.session_id],
        )
        .expect("seed exhausted turn count");
    }

    let error =
        resolve_turn_offset(&harness.event_store, &harness.session_id, u32::MAX).unwrap_err();
    assert!(matches!(
        error,
        crate::domains::agent::r#loop::errors::RuntimeError::Internal(_)
    ));
}
