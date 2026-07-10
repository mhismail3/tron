use super::*;
use crate::domains::agent::context::types::{CompactionConfig, ContextManagerConfig};
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::primitive_surface::PrimitiveExecutionTarget;
use crate::domains::agent::r#loop::types::CapabilityInvocationExecutionResult;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::{EventStore, ListEventsOptions};
use crate::engine::{
    ActorId, AuthorityGrantId, AuthorityRequirement, EffectClass, EngineHostHandle,
    FunctionDefinition, FunctionId, Invocation, RiskLevel, VisibilityScope, WorkerDefinition,
    WorkerId, WorkerKind,
};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::events::{AssistantMessage, TronEvent};
use crate::shared::protocol::messages::CapabilityInvocationDraft;
use crate::shared::protocol::messages::{CapabilityResultMessageContent, Message};
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use async_trait::async_trait;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use tokio_util::sync::CancellationToken;

fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
    make_exec_result_with_details(content, None)
}

fn make_exec_result_with_details(
    content: CapabilityResultBody,
    details: Option<Value>,
) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        result: CapabilityResult {
            content,
            details,
            is_error: None,
            stop_turn: None,
        },
        duration_ms: 100,
        stops_turn: false,
    }
}

#[test]
fn primitive_identity_canonicalizes_only_supported_operation_payloads() {
    let mut args = Map::new();
    args.insert("operationName".to_owned(), json!("file_read"));

    let identity = primitive_identity_json("execute", &args, None, None);

    assert!(identity.get("operationName").is_none());
    assert_eq!(identity["requestedOperationName"], "file_read");
}

#[test]
fn primitive_identity_exposes_valid_execute_operation() {
    let mut args = Map::new();
    args.insert("operation".to_owned(), json!("log_recent"));

    let identity = primitive_identity_json("execute", &args, None, None);

    assert_eq!(identity["operationName"], "log_recent");
    assert!(identity.get("requestedOperationName").is_none());
}

#[test]
fn provider_operation_identity_preserves_unsupported_request() {
    let mut args = Map::new();
    args.insert(
        "operation".to_owned(),
        json!("capability_shadow_trial_request_list"),
    );

    assert_eq!(
        provider_operation_name_from_map(&args),
        "capability_shadow_trial_request_list"
    );
}

#[test]
fn provider_operation_identity_normalizes_malformed_requests() {
    for args in [
        Map::new(),
        Map::from_iter([("operation".to_owned(), json!(42))]),
        Map::from_iter([("operation".to_owned(), json!("   "))]),
    ] {
        assert_eq!(provider_operation_name_from_map(&args), "unknown");
    }
}

#[test]
fn result_identity_does_not_promote_unsupported_operation_details() {
    let base_identity = primitive_identity_json("execute", &Map::new(), None, None);
    let result = make_exec_result_with_details(
        CapabilityResultBody::Text("failed".into()),
        Some(json!({
            "operation": "file_read",
            "traceId": "trace_1"
        })),
    );

    let identity = result_identity_json("execute", base_identity, &result);

    assert!(identity.get("operationName").is_none());
    assert_eq!(identity["traceId"], "trace_1");
}

#[test]
fn extract_result_text_drops_images() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("captured"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let text = extract_result_text(&exec);
    assert_eq!(text, "captured");
    assert!(!text.contains("base64"));
}

struct PhasePersistenceHarness {
    emitter: Arc<EventEmitter>,
    persister: EventPersister,
    store: Arc<EventStore>,
    session_id: String,
    counter: AtomicI64,
    rx: tokio::sync::broadcast::Receiver<TronEvent>,
}

async fn phase_persistence_harness() -> PhasePersistenceHarness {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
    let emitter = Arc::new(EventEmitter::new());
    let rx = emitter.subscribe();
    let persister = EventPersister::new(Arc::clone(&store));
    PhasePersistenceHarness {
        emitter,
        persister,
        store,
        session_id: session.session.id,
        counter: AtomicI64::new(0),
        rx,
    }
}

#[derive(Clone)]
struct DelayedCapabilityHandler;

#[async_trait]
impl crate::engine::InProcessFunctionHandler for DelayedCapabilityHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        let trace_id = invocation
            .payload
            .get("traceId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let delay_ms = if trace_id == "slow" { 25 } else { 0 };
        if delay_ms > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }
        let label = trace_id;
        serde_json::to_value(CapabilityResult {
            content: CapabilityResultBody::Text(format!("done-{label}")),
            details: Some(json!({
                "operation": "log_recent",
                "themeColor": "#10B981",
                "presentationHints": {
                    "chipTitle": format!("Log {label}"),
                    "themeColor": "#10B981"
                }
            })),
            is_error: Some(false),
            stop_turn: None,
        })
        .map_err(|error| crate::engine::EngineError::HandlerFailed(error.to_string()))
    }
}

async fn phase_engine_surface() -> (EngineHostHandle, ResolvedPrimitiveSurface) {
    let engine_host = EngineHostHandle::new_in_memory().expect("engine host");
    engine_host
        .register_worker(
            WorkerDefinition::new(
                WorkerId::new("capability").expect("worker id"),
                WorkerKind::InProcess,
                ActorId::new("capability-owner").expect("actor id"),
                AuthorityGrantId::new("capability-grant").expect("grant id"),
            )
            .with_namespace_claim("capability"),
            false,
        )
        .await
        .expect("register worker");

    let function_id = FunctionId::new("capability::phase_lifecycle").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Phase lifecycle test".to_owned(),
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"));
    engine_host
        .register_function(
            function.clone(),
            Some(Arc::new(DelayedCapabilityHandler)),
            false,
        )
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        PrimitiveExecutionTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            execution_mode: ExecutionMode::Parallel,
        },
    );
    (
        engine_host,
        ResolvedPrimitiveSurface {
            capabilities: Vec::new(),
            targets_by_name,
            turn_stopping_capabilities: HashSet::new(),
        },
    )
}

fn context_manager_for_workdir(working_directory: &str) -> ContextManager {
    ContextManager::new(ContextManagerConfig {
        model: "m".to_owned(),
        system_prompt: Some("system".to_owned()),
        working_directory: Some(working_directory.to_owned()),
        capabilities: Vec::new(),
        compaction: CompactionConfig::default(),
    })
}

fn stream_result_with_invocations(
    capability_invocations: Vec<CapabilityInvocationDraft>,
) -> StreamResult {
    StreamResult {
        message: AssistantMessage {
            content: Vec::new(),
            token_usage: None,
        },
        capability_invocations,
        stop_reason: "capability_invocation".to_owned(),
        token_usage: None,
        interrupted: false,
        partial_content: None,
        ttft_ms: None,
    }
}

async fn collect_broadcasts(
    rx: &mut tokio::sync::broadcast::Receiver<TronEvent>,
    expected_count: usize,
) -> Vec<TronEvent> {
    let mut events = Vec::with_capacity(expected_count);
    while events.len() < expected_count {
        let event = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        events.push(event);
    }
    events
}

fn persisted_rows(store: &EventStore, sid: &str, event_type: &str) -> Vec<EventRow> {
    store
        .get_events_by_session(sid, &ListEventsOptions::default())
        .unwrap()
        .into_iter()
        .filter(|event| event.event_type == event_type)
        .collect()
}

async fn assert_provider_result_identity_survives_reconstruction(
    arguments: Map<String, Value>,
    expected_operation: &str,
) {
    let h = phase_persistence_harness().await;
    let (engine_host, surface) = phase_engine_surface().await;
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = crate::shared::foundation::paths::normalize_working_directory(
        tempdir.path().to_str().expect("utf8 tempdir"),
    )
    .expect("normalized working directory")
    .display()
    .to_string();
    let mut context_manager = context_manager_for_workdir(&working_directory);
    let cancel = CancellationToken::new();
    let invocation_id = format!("call-{expected_operation}");
    let stream_result = stream_result_with_invocations(vec![CapabilityInvocationDraft::new(
        invocation_id.clone(),
        "execute",
        arguments.clone(),
    )]);

    h.persister
        .append_with_runtime_sequence(
            &h.session_id,
            EventType::MessageAssistant,
            json!({
                "content": [{
                    "type": "capability_invocation",
                    "id": invocation_id,
                    "name": "execute",
                    "arguments": arguments,
                }],
                "turn": 1,
            }),
            Some(&h.counter),
        )
        .await
        .expect("persist assistant invocation");

    let outcome = execute_capability_invocation_phase(CapabilityInvocationPhaseParams {
        turn: 1,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: &h.session_id,
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: None,
        engine_host: Some(&engine_host),
        run_id: Some("run-operation-identity"),
        provider_type: "openai",
        trace_id: None,
        parent_invocation_id: None,
    })
    .await;
    assert_eq!(outcome.capability_invocations_executed, 1);

    let live_content = context_manager
        .messages_slice()
        .iter()
        .find_map(|message| match message {
            Message::CapabilityResult {
                invocation_id: id,
                content: CapabilityResultMessageContent::Text(content),
                ..
            } if id == &invocation_id => Some(content.clone()),
            _ => None,
        })
        .expect("live provider result");
    assert_eq!(
        serde_json::from_str::<Value>(&live_content).expect("provider envelope")["operation"],
        expected_operation
    );

    h.persister.flush().await.expect("flush persisted events");
    let completed = persisted_rows(&h.store, &h.session_id, "capability.invocation.completed");
    assert_eq!(completed.len(), 1);
    let completed_payload: Value =
        serde_json::from_str(&completed[0].payload).expect("completed event payload");
    let persisted_content = completed_payload["modelContextContent"]
        .as_str()
        .expect("persisted model context content");
    assert_eq!(persisted_content.as_bytes(), live_content.as_bytes());

    let reconstructed =
        crate::domains::agent::r#loop::orchestrator::session_reconstructor::reconstruct(
            &h.store,
            &h.session_id,
        )
        .expect("reconstruct session");
    let reconstructed_content = reconstructed
        .messages
        .iter()
        .find_map(|message| match message {
            Message::CapabilityResult {
                invocation_id: id,
                content: CapabilityResultMessageContent::Text(content),
                ..
            } if id == &invocation_id => Some(content),
            _ => None,
        })
        .expect("reconstructed provider result");
    assert_eq!(reconstructed_content.as_bytes(), live_content.as_bytes());
}

#[tokio::test]
async fn unsupported_operation_provider_result_is_stable_after_reconstruction() {
    let mut arguments = Map::new();
    arguments.insert(
        "operation".to_owned(),
        json!("capability_shadow_trial_request_list"),
    );

    assert_provider_result_identity_survives_reconstruction(
        arguments,
        "capability_shadow_trial_request_list",
    )
    .await;
}

#[tokio::test]
async fn malformed_operation_provider_results_are_stable_after_reconstruction() {
    for arguments in [
        Map::new(),
        Map::from_iter([("operation".to_owned(), json!(42))]),
        Map::from_iter([("operation".to_owned(), json!("   "))]),
    ] {
        assert_provider_result_identity_survives_reconstruction(arguments, "unknown").await;
    }
}

#[tokio::test]
async fn parallel_phase_broadcasts_all_persisted_starts_before_first_completion() {
    let mut h = phase_persistence_harness().await;
    let (engine_host, surface) = phase_engine_surface().await;
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = crate::shared::foundation::paths::normalize_working_directory(
        tempdir.path().to_str().expect("utf8 tempdir"),
    )
    .expect("normalized working directory")
    .display()
    .to_string();
    let mut context_manager = context_manager_for_workdir(&working_directory);
    let cancel = CancellationToken::new();
    let stream_result = stream_result_with_invocations(vec![
        CapabilityInvocationDraft::new("call-slow", "execute", {
            let mut args = Map::new();
            args.insert("operation".to_owned(), json!("log_recent"));
            args.insert("traceId".to_owned(), json!("slow"));
            args
        }),
        CapabilityInvocationDraft::new("call-fast", "execute", {
            let mut args = Map::new();
            args.insert("operation".to_owned(), json!("log_recent"));
            args.insert("traceId".to_owned(), json!("fast"));
            args
        }),
    ]);

    let outcome = execute_capability_invocation_phase(CapabilityInvocationPhaseParams {
        turn: 7,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: &h.session_id,
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: None,
        engine_host: Some(&engine_host),
        run_id: Some("run-phase"),
        provider_type: "openai",
        trace_id: None,
        parent_invocation_id: None,
    })
    .await;

    assert_eq!(outcome.capability_invocations_executed, 2);
    let events = collect_broadcasts(&mut h.rx, 5).await;
    let lifecycle: Vec<&TronEvent> = events
        .iter()
        .filter(|event| {
            matches!(
                event,
                TronEvent::CapabilityInvocationStarted { .. }
                    | TronEvent::CapabilityInvocationCompleted { .. }
            )
        })
        .collect();
    assert_eq!(lifecycle.len(), 4, "no duplicate lifecycle events");
    assert!(matches!(
        lifecycle[0],
        TronEvent::CapabilityInvocationStarted { .. }
    ));
    assert!(matches!(
        lifecycle[1],
        TronEvent::CapabilityInvocationStarted { .. }
    ));
    assert!(matches!(
        lifecycle[2],
        TronEvent::CapabilityInvocationCompleted { .. }
    ));

    h.persister.flush().await.unwrap();
    let persisted_starts = persisted_rows(&h.store, &h.session_id, "capability.invocation.started");
    let persisted_completions =
        persisted_rows(&h.store, &h.session_id, "capability.invocation.completed");
    assert_eq!(persisted_starts.len(), 2);
    assert_eq!(persisted_completions.len(), 2);

    let live_start_sequences: Vec<i64> = lifecycle
        .iter()
        .filter_map(|event| match event {
            TronEvent::CapabilityInvocationStarted { .. } => event.sequence(),
            _ => None,
        })
        .collect();
    let persisted_start_sequences: Vec<i64> =
        persisted_starts.iter().map(|row| row.sequence).collect();
    assert_eq!(live_start_sequences, persisted_start_sequences);

    let live_completion_sequences: Vec<i64> = lifecycle
        .iter()
        .filter_map(|event| match event {
            TronEvent::CapabilityInvocationCompleted { .. } => event.sequence(),
            _ => None,
        })
        .collect();
    let mut persisted_completion_sequences: Vec<i64> = persisted_completions
        .iter()
        .map(|row| row.sequence)
        .collect();
    persisted_completion_sequences.sort_unstable();
    let mut sorted_live_completion_sequences = live_completion_sequences.clone();
    sorted_live_completion_sequences.sort_unstable();
    assert_eq!(
        sorted_live_completion_sequences,
        persisted_completion_sequences
    );

    let started = lifecycle
        .iter()
        .find_map(|event| match event {
            TronEvent::CapabilityInvocationStarted {
                invocation_id,
                model_primitive_name,
                arguments,
                capability_identity,
                ..
            } if invocation_id == "call-slow" => {
                Some((model_primitive_name, arguments, capability_identity))
            }
            _ => None,
        })
        .expect("slow started event");
    assert_eq!(started.0, "execute");
    assert_eq!(started.1.as_ref().unwrap()["traceId"], "slow");
    assert_eq!(started.2.model_primitive_name.as_deref(), Some("execute"));
    assert_eq!(started.2.operation_name.as_deref(), Some("log_recent"));

    let completed = lifecycle
        .iter()
        .find_map(|event| match event {
            TronEvent::CapabilityInvocationCompleted {
                invocation_id,
                result,
                capability_identity,
                ..
            } if invocation_id == "call-fast" => Some((result, capability_identity)),
            _ => None,
        })
        .expect("fast completed event");
    assert_eq!(completed.0.as_ref().unwrap().is_error, Some(false));
    assert_eq!(completed.1.operation_name.as_deref(), Some("log_recent"));
    assert_eq!(completed.1.theme_color.as_deref(), Some("#10B981"));
}

#[tokio::test]
async fn phase_does_not_broadcast_starts_when_start_persistence_fails() {
    let mut h = phase_persistence_harness().await;
    h.persister.worker_handle.abort();
    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    let (_engine_host, surface) = phase_engine_surface().await;
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = tempdir.path().to_str().expect("utf8 tempdir");
    let mut context_manager = context_manager_for_workdir(working_directory);
    let cancel = CancellationToken::new();
    let stream_result = stream_result_with_invocations(vec![CapabilityInvocationDraft::new(
        "call-1",
        "execute",
        Map::new(),
    )]);

    let outcome = execute_capability_invocation_phase(CapabilityInvocationPhaseParams {
        turn: 1,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: &h.session_id,
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: None,
        engine_host: None,
        run_id: Some("run-phase"),
        provider_type: "openai",
        trace_id: None,
        parent_invocation_id: None,
    })
    .await;

    assert_eq!(outcome.capability_invocations_executed, 0);
    let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
    assert!(
        result.is_err(),
        "no live start should broadcast when start persistence fails: {result:?}"
    );
}
