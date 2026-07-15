use super::*;
use async_trait::async_trait;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::{ModelResponder, ModelResponderFactory, ModelResponseError};
use crate::domains::session::event_store::{
    ConnectionConfig, ConnectionPool, EventStore, ListEventsOptions, new_in_memory, run_migrations,
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
            event_store: self.event_store.clone(),
            shutdown_token: None,
            shutdown_coordinator: None,
            engine_host: crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
            sequence_counter: None,
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
    assert_eq!(
        terminal_error_code(&mut outcome.events),
        EVENT_STORE_FAILURE
    );
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
