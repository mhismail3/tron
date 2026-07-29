use super::*;
use async_trait::async_trait;
use futures::stream;
use serde_json::Value;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::{
    ModelResponder, ModelResponderFactory, ModelResponderInfo, ModelResponse, ModelResponseError,
    ModelResponseRequest, ModelResponseStream,
};
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, AppendOptions, ConnectionConfig, ConnectionPool, EventStore,
    EventType, ListEventsOptions, NewAgentDelivery, ensure_schema, new_in_memory,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent, TronEvent};
use crate::shared::server::errors::EVENT_STORE_FAILURE;
use crate::shared::server::failure::RUNTIME_PERSISTENCE_ERROR;

struct CountingFactory {
    create_calls: Arc<AtomicUsize>,
}

struct LatchResponder {
    started: Arc<tokio::sync::Semaphore>,
    release: Arc<tokio::sync::Semaphore>,
}

#[async_trait]
impl ModelResponder for LatchResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::OpenAi,
            provider_name: "openai",
            model: "mock".to_owned(),
            context_window: 200_000,
        }
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        self.started.add_permits(1);
        self.release.acquire().await.unwrap().forget();
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: "Provider began independently.".to_owned(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("Provider began independently.")],
                        token_usage: None,
                    },
                    stop_reason: "end_turn".to_owned(),
                }),
            ])) as ModelResponseStream,
        })
    }
}

struct LatchFactory {
    responder: Arc<LatchResponder>,
}

#[async_trait]
impl ModelResponderFactory for LatchFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _api_settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(self.responder.clone())
    }
}

#[derive(Clone, Copy)]
enum OptionalHookKind {
    Continuity,
    Relevance,
    Mailbox,
}

struct BlockingOptionalHook {
    kind: OptionalHookKind,
    started: Arc<tokio::sync::Semaphore>,
    release: Arc<tokio::sync::Semaphore>,
}

#[async_trait]
impl crate::engine::InProcessFunctionHandler for BlockingOptionalHook {
    async fn invoke(&self, _invocation: crate::engine::Invocation) -> crate::engine::Result<Value> {
        self.started.add_permits(1);
        self.release.acquire().await.unwrap().forget();
        Ok(match self.kind {
            OptionalHookKind::Continuity => serde_json::json!({"handled":false}),
            OptionalHookKind::Relevance => {
                serde_json::json!({"handled":false,"rankings":[]})
            }
            OptionalHookKind::Mailbox => {
                serde_json::json!({"handled":true,"selectedDeliveryIds":[]})
            }
        })
    }
}

fn register_blocking_optional_hook(
    host: &crate::engine::EngineHostHandle,
    function_id: &str,
    kind: OptionalHookKind,
    started: Arc<tokio::sync::Semaphore>,
    release: Arc<tokio::sync::Semaphore>,
) {
    let definition = crate::engine::FunctionDefinition::new(
        crate::engine::FunctionId::new(function_id).unwrap(),
        crate::engine::WorkerId::new("worker_kernel").unwrap(),
        "Blocked optional policy worker",
        crate::engine::FunctionVisibility::Internal,
        crate::engine::EffectClass::ExternalSideEffect,
    )
    .with_idempotency(crate::engine::IdempotencyContract::session())
    .with_request_schema(serde_json::json!({"type":"object"}))
    .with_response_schema(serde_json::json!({"type":"object"}));
    host.register_function_for_setup(
        definition,
        Arc::new(BlockingOptionalHook {
            kind,
            started,
            release,
        }),
    )
    .unwrap();
}

fn register_semantic_candidate(host: &crate::engine::EngineHostHandle, suffix: &str) {
    let mut definition = crate::engine::FunctionDefinition::new(
        crate::engine::FunctionId::new(format!("test::{suffix}")).unwrap(),
        crate::engine::WorkerId::new(format!("candidate-{suffix}")).unwrap(),
        "Optional provider worker candidate",
        crate::engine::FunctionVisibility::Public,
        crate::engine::EffectClass::PureRead,
    )
    .with_request_schema(serde_json::json!({"type":"object"}))
    .with_response_schema(serde_json::json!({"type":"object"}));
    definition.model_tool = Some(crate::engine::ModelToolContract {
        name: format!("candidate_{suffix}"),
        audience: crate::engine::ModelToolAudience::Ordinary,
        order: None,
        group: None,
        worker: Some(crate::engine::DirectWorkerToolContract {
            worker_id: format!("candidate-{suffix}"),
            worker_name: format!("Candidate {suffix}"),
            worker_description: "Optional provider worker candidate".to_owned(),
            worker_version: "v1".to_owned(),
            runner_kind: "command".to_owned(),
            updated_at: String::new(),
            intents: vec!["optional provider worker".to_owned()],
            examples: vec!["optional provider worker".to_owned()],
            provenance: vec!["test".to_owned()],
        }),
    });
    host.register_function_for_setup(
        definition,
        Arc::new(BlockingOptionalHook {
            kind: OptionalHookKind::Mailbox,
            started: Arc::new(tokio::sync::Semaphore::new(0)),
            release: Arc::new(tokio::sync::Semaphore::new(0)),
        }),
    )
    .unwrap();
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
            ensure_schema(&conn).expect("event schema");
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
        self.execute_trigger(
            run_id,
            crate::domains::agent::r#loop::types::AgentRunTrigger::UserPrompt {
                prompt: "must preserve durable history".to_owned(),
            },
        )
        .await
    }

    async fn execute_trigger(
        &self,
        run_id: &str,
        trigger: crate::domains::agent::r#loop::types::AgentRunTrigger,
    ) -> PromptFailureOutcome {
        self.execute_trigger_with_factory(
            run_id,
            trigger,
            Arc::new(CountingFactory {
                create_calls: self.create_calls.clone(),
            }),
        )
        .await
    }

    async fn execute_trigger_with_factory(
        &self,
        run_id: &str,
        trigger: crate::domains::agent::r#loop::types::AgentRunTrigger,
        responder_factory: Arc<dyn ModelResponderFactory>,
    ) -> PromptFailureOutcome {
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
            responder_factory,
            settings: crate::domains::settings::TronSettings::default(),
            event_store: self.event_store.clone(),
            shutdown_token: None,
            engine_host: crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
            server_origin: "localhost:9847".to_owned(),
            run_id: run_id.to_owned(),
            model: self.model.clone(),
            working_dir: self.working_dir.clone(),
            request: PromptRequest {
                session_id: self.session_id.clone(),
                trigger,
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

#[tokio::test]
async fn delivery_wake_reaches_provider_without_fabricating_a_user_message() {
    let harness = PromptFailureHarness::new();
    let provider_started = Arc::new(tokio::sync::Semaphore::new(0));
    let provider_release = Arc::new(tokio::sync::Semaphore::new(1));
    let session = harness
        .event_store
        .get_session(&harness.session_id)
        .unwrap()
        .unwrap();
    let delivery = harness
        .event_store
        .create_agent_delivery(&NewAgentDelivery {
            idempotency_key: "delivery-wake:no-user".to_owned(),
            source_kind: AgentDeliverySourceKind::AgentMessage,
            intent: Some(AgentDeliveryIntent::Information),
            source_session_id: Some(session.id.clone()),
            source_workspace_id: session.workspace_id,
            source_invocation_id: Some("schedule-one".to_owned()),
            source_trace_id: Some("trace-delivery-wake".to_owned()),
            source_root_invocation_id: None,
            causal_depth: 1,
            target: AgentDeliveryTarget::Session {
                session_id: session.id,
            },
            wake_policy: AgentDeliveryWakePolicy::Wake,
            boundary: AgentDeliveryBoundary::NextRun,
            originating_run_id: None,
            arrived_during_run_id: None,
            defer_until_run_id: None,
            result_invocation_id: None,
            content: "A peer update is ready.".to_owned(),
            not_before: None,
            expires_at: None,
        })
        .unwrap();

    let mut outcome = harness
        .execute_trigger_with_factory(
            "run-delivery-wake",
            crate::domains::agent::r#loop::types::AgentRunTrigger::DeliveryWake {
                delivery_ids: vec![delivery.delivery_id.clone()],
            },
            Arc::new(LatchFactory {
                responder: Arc::new(LatchResponder {
                    started: provider_started.clone(),
                    release: provider_release,
                }),
            }),
        )
        .await;

    assert_eq!(provider_started.available_permits(), 1);
    let rows = harness
        .event_store
        .get_events_by_session(&harness.session_id, &ListEventsOptions::default())
        .unwrap();
    assert!(
        rows.iter().all(|row| row.event_type != "message.user"),
        "delivery-only execution must not create user history"
    );
    let assistant = rows
        .iter()
        .find(|row| row.event_type == "message.assistant")
        .expect("delivery wake assistant continuation");
    let assistant_payload: Value =
        serde_json::from_str(&assistant.payload).expect("assistant payload JSON");
    assert_eq!(
        assistant_payload["agentDeliveryContinuation"]["deliveries"][0]["deliveryId"],
        delivery.delivery_id
    );
    assert_eq!(
        assistant_payload["agentDeliveryContinuation"]["deliveries"][0]["sourceKind"],
        "agent_message"
    );
    assert_eq!(
        harness
            .event_store
            .agent_delivery(
                assistant_payload["agentDeliveryContinuation"]["deliveries"][0]["deliveryId"]
                    .as_str()
                    .unwrap()
            )
            .unwrap()
            .unwrap()
            .projection_status(),
        "observed"
    );
    assert!(
        std::iter::from_fn(|| outcome.events.try_recv().ok())
            .all(|event| event.event_type() != "message_user"),
        "delivery-only execution must not emit a user bubble"
    );
}

#[tokio::test]
async fn initial_provider_call_does_not_wait_for_optional_policy_workers() {
    let pool = new_in_memory(&ConnectionConfig {
        pool_size: 8,
        ..ConnectionConfig::default()
    })
    .unwrap();
    ensure_schema(&pool.get().unwrap()).unwrap();
    let event_store = Arc::new(EventStore::new(pool));
    let session = event_store
        .create_session("mock", "/tmp/project", Some("Latency boundary"), None)
        .unwrap();
    let session_id = session.session.id.clone();
    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let run_id = "run-optional-policy-latch";
    let started_run = orchestrator.begin_run(&session_id, run_id).unwrap();
    let host = crate::engine::EngineHostHandle::new_in_memory().unwrap();
    let optional_started = Arc::new(tokio::sync::Semaphore::new(0));
    let optional_release = Arc::new(tokio::sync::Semaphore::new(0));
    register_blocking_optional_hook(
        &host,
        crate::domains::worker_kernel::CONTINUITY_CONTEXT_FUNCTION,
        OptionalHookKind::Continuity,
        optional_started.clone(),
        optional_release.clone(),
    );
    register_blocking_optional_hook(
        &host,
        crate::domains::worker_kernel::WORKER_RELEVANCE_FUNCTION,
        OptionalHookKind::Relevance,
        optional_started.clone(),
        optional_release.clone(),
    );
    register_blocking_optional_hook(
        &host,
        "worker_kernel::mailbox_curation",
        OptionalHookKind::Mailbox,
        optional_started.clone(),
        optional_release.clone(),
    );
    for ordinal in 0..13 {
        register_semantic_candidate(&host, &format!("optional-{ordinal}"));
    }

    let mailbox_host = host.clone();
    let mailbox_session_id = session_id.clone();
    let mailbox = tokio::spawn(async move {
        let causal = crate::engine::CausalContext::new(
            crate::engine::ActorId::new("system:mailbox-cursor-test").unwrap(),
            crate::engine::ActorKind::System,
            crate::engine::TraceId::generate(),
        )
        .with_session_id(mailbox_session_id.clone())
        .with_idempotency_key("mailbox-cursor-test");
        mailbox_host
            .invoke(crate::engine::Invocation::new_sync(
                crate::engine::FunctionId::new("worker_kernel::mailbox_curation").unwrap(),
                serde_json::json!({
                    "sessionId":mailbox_session_id,
                    "candidates":[]
                }),
                causal,
            ))
            .await
    });

    let provider_started = Arc::new(tokio::sync::Semaphore::new(0));
    let provider_release = Arc::new(tokio::sync::Semaphore::new(0));
    let responder = Arc::new(LatchResponder {
        started: provider_started.clone(),
        release: provider_release.clone(),
    });
    let execute = tokio::spawn(execute_prompt_run(PromptRunPlan {
        started_run,
        orchestrator: orchestrator.clone(),
        session_manager,
        responder_factory: Arc::new(LatchFactory { responder }),
        settings: crate::domains::settings::TronSettings::default(),
        event_store,
        shutdown_token: None,
        engine_host: host,
        server_origin: "localhost:9847".to_owned(),
        run_id: run_id.to_owned(),
        model: "mock".to_owned(),
        working_dir: "/tmp/project".to_owned(),
        request: PromptRequest {
            session_id: session_id.clone(),
            trigger: crate::domains::agent::r#loop::types::AgentRunTrigger::UserPrompt {
                prompt: "optional provider worker".to_owned(),
            },
            reasoning_level: None,
            attachments: None,
            engine_causality: None,
        },
    }));

    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        optional_started.acquire_many(3),
    )
    .await
    .expect("all optional policies should begin")
    .unwrap()
    .forget();
    tokio::time::timeout(
        std::time::Duration::from_secs(2),
        provider_started.acquire(),
    )
    .await
    .expect("provider should begin while optional policies are blocked")
    .unwrap()
    .forget();

    optional_release.add_permits(3);
    provider_release.add_permits(1);
    execute.await.unwrap();
    assert!(mailbox.await.unwrap().error.is_none());
    assert!(!orchestrator.has_active_run(&session_id));
}

#[test]
fn worker_audit_sessions_are_ineligible_for_optional_semantic_preparation() {
    let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
    ensure_schema(&pool.get().unwrap()).unwrap();
    let event_store = EventStore::new(pool);
    let ordinary = event_store
        .create_session("mock", "/tmp/project", Some("Ordinary"), None)
        .unwrap()
        .session;
    let worker = event_store
        .create_worker_session("mock", "/tmp/worker", Some("Worker audit"), None)
        .unwrap()
        .session;

    assert!(optional_context_is_eligible(&ordinary));
    assert!(
        !optional_context_is_eligible(&worker),
        "kernel-authored worker prompts must never launch Continuity or semantic ranking"
    );
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
async fn unresolved_prior_tool_blocks_prompt_until_atomic_repair_commits() {
    let harness = PromptFailureHarness::new();
    for (event_type, payload) in [
        (EventType::StreamTurnStart, serde_json::json!({"turn": 1})),
        (
            EventType::MessageAssistant,
            serde_json::json!({
                "turn": 1,
                "content": [{
                    "type": "tool_invocation",
                    "id": "call-unresolved",
                    "name": "test_tool",
                    "arguments": {"operation": "observe"}
                }],
                "model": "mock",
                "stopReason": "tool_invocation"
            }),
        ),
        (
            EventType::ToolInvocationStarted,
            serde_json::json!({
                "turn": 1,
                "invocationId": "call-unresolved",
                "toolName": "test_tool",
                "arguments": {"operation": "observe"}
            }),
        ),
        (
            EventType::TurnFailed,
            serde_json::json!({
                "turn": 1,
                "error": "tool terminal persistence failed"
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
            .expect("seed failed tool turn");
    }
    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch(
            "CREATE TRIGGER reject_tool_repair
             BEFORE INSERT ON events
             WHEN NEW.type = 'tool.invocation.completed'
             BEGIN
               SELECT RAISE(FAIL, 'forced tool repair rejection');
             END;",
        )
        .expect("repair rejection trigger");
    }

    let mut blocked = harness.execute("run-blocked-by-prior-tool").await;

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
            .all(|row| { row.event_type != EventType::ToolInvocationCompleted.as_str() }),
        "failed repair must leave no partial terminal row"
    );
    assert_eq!(
        terminal_error_code(&mut blocked.events),
        RUNTIME_PERSISTENCE_ERROR
    );

    {
        let conn = harness.pool.get().expect("event connection");
        conn.execute_batch("DROP TRIGGER reject_tool_repair;")
            .expect("remove repair rejection");
    }
    let mut admitted = harness.execute("run-after-tool-repair").await;

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
            row.event_type == EventType::ToolInvocationCompleted.as_str()
                && row.invocation_id.as_deref() == Some("call-unresolved")
        })
        .expect("durable repaired tool completion");
    let live_repair = std::iter::from_fn(|| admitted.events.try_recv().ok())
        .find_map(|event| match event {
            TronEvent::ToolInvocationCompleted {
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
