use super::*;
use crate::domains::agent::context::types::{CompactionConfig, ContextManagerConfig};
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::primitive_surface::PrimitiveExecutionTarget;
use crate::domains::agent::r#loop::types::ToolInvocationExecutionResult;
use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::schema::ensure_schema;
use crate::domains::session::event_store::{EventStore, ListEventsOptions};
use crate::engine::{
    EffectClass, EngineHostHandle, FunctionDefinition, FunctionId, FunctionVisibility, Invocation,
    RiskLevel, WorkerId,
};
use crate::shared::protocol::content::ToolResultContent;
use crate::shared::protocol::events::{AssistantMessage, TronEvent};
use crate::shared::protocol::messages::ToolInvocationDraft;
use crate::shared::protocol::messages::{Message, ToolResultMessageContent};
use crate::shared::protocol::model_tools::{ToolResult, ToolResultBody};
use async_trait::async_trait;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use tokio_util::sync::CancellationToken;

fn make_exec_result(content: ToolResultBody) -> ToolInvocationExecutionResult {
    make_exec_result_with_details(content, None)
}

fn make_exec_result_with_details(
    content: ToolResultBody,
    details: Option<Value>,
) -> ToolInvocationExecutionResult {
    ToolInvocationExecutionResult {
        result: ToolResult {
            content,
            details,
            is_error: None,
        },
        duration_ms: 100,
    }
}

#[test]
fn tool_event_context_contains_only_causal_fields() {
    let args = Map::from_iter([("operation".to_owned(), json!("worker_owned_field"))]);

    let identity = tool_event_context_json(None, None, None);

    assert!(identity.get("toolName").is_none());
    assert!(identity.get("presentationHints").is_none());
    assert_eq!(args["operation"], "worker_owned_field");
}

#[test]
fn result_identity_keeps_trace_and_presentation_evidence_without_operation_routing() {
    let base_identity = tool_event_context_json(
        None,
        None,
        Some(json!({
            "surfaceKind": "worker",
            "workerId": "research"
        })),
    );
    let result = make_exec_result_with_details(
        ToolResultBody::Text("complete".into()),
        Some(json!({
            "operation": "worker_owned_field",
            "traceId": "trace_1",
            "presentationHints": {
                "surfaceKind": "worker",
                "workerId": "research",
                "runnerKind": "agent",
                "themeColor": "#10B981"
            }
        })),
    );

    let identity = result_event_context_json(base_identity, &result);

    assert!(identity.get("toolName").is_none());
    assert_eq!(identity["traceId"], "trace_1");
    assert_eq!(identity["themeColor"], "#10B981");
    assert_eq!(identity["presentationHints"]["surfaceKind"], "worker");
    assert_eq!(identity["presentationHints"]["runnerKind"], "agent");
}

#[test]
fn extract_result_text_drops_images() {
    let exec = make_exec_result(ToolResultBody::Blocks(vec![
        ToolResultContent::text("captured"),
        ToolResultContent::image("base64data", "image/png"),
    ]));
    let text = extract_result_text(&exec);
    assert_eq!(text, "captured");
    assert!(!text.contains("base64"));
}

#[test]
fn durable_completion_redacts_one_time_credentials_but_leaves_live_result_intact() {
    let token = "trwh_0123456789abcdef0123456789abcdef";
    let invocation = ToolInvocationDraft::new("call-secret", "worker_upsert", Map::new());
    let result = make_exec_result_with_details(
        ToolResultBody::Text(format!(r#"{{"token":"{token}"}}"#)),
        Some(json!({
            "webhooks": [{"token": token, "path": "/hooks/research"}],
            "status": "active"
        })),
    );

    let payload = executed_completion_payload(
        &invocation,
        &result,
        &provider_result_text(&result.result),
        Some("run-secret"),
        None,
        None,
        None,
    );

    assert!(!payload.to_string().contains(token));
    assert_eq!(payload["details"]["webhooks"][0]["token"], "****");
    assert!(payload["content"].as_str().unwrap().contains("****"));
    assert!(provider_result_text(&result.result).contains(token));
}

#[test]
fn oversized_completion_retains_exact_audit_output_and_bounded_model_context() {
    let invocation = ToolInvocationDraft::new("call-large", "process_run", Map::new());
    let raw = format!(r#"{{"stdout":"{}","exitCode":0}}"#, "QUFB".repeat(235_000));
    let result = make_exec_result(ToolResultBody::Text(raw.clone()));
    let provider_text = super::super::turn_context::project_provider_result_text(
        &provider_result_text(&result.result),
    );

    let payload = executed_completion_payload(
        &invocation,
        &result,
        &provider_text,
        Some("run-large"),
        None,
        None,
        None,
    );

    assert_eq!(payload["content"].as_str(), Some(raw.as_str()));
    let model_context = payload["modelContextContent"]
        .as_str()
        .expect("oversized result should have a separate model projection");
    assert!(model_context.len() <= super::super::turn_context::MAX_PROVIDER_TOOL_RESULT_BYTES);
    assert!(model_context.contains("Tron model-context projection"));
    assert!(model_context.contains(&format!("originalBytes={}", raw.len())));
    assert_ne!(model_context, raw);
}

struct PhasePersistenceHarness {
    emitter: Arc<EventEmitter>,
    persister: EventPersister,
    store: Arc<EventStore>,
    session_id: String,
    counter: AtomicI64,
    rx: tokio::sync::broadcast::Receiver<TronEvent>,
    invocation_abort_registry: Arc<InvocationAbortRegistry>,
}

async fn phase_persistence_harness() -> PhasePersistenceHarness {
    phase_persistence_harness_with_trigger(None).await
}

async fn phase_persistence_harness_with_trigger(trigger: Option<&str>) -> PhasePersistenceHarness {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        ensure_schema(&conn).unwrap();
        if let Some(trigger) = trigger {
            conn.execute_batch(trigger)
                .expect("install failure trigger");
        }
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
        invocation_abort_registry: Arc::new(InvocationAbortRegistry::new()),
    }
}

#[derive(Clone)]
struct DelayedToolHandler;

#[async_trait]
impl crate::engine::InProcessFunctionHandler for DelayedToolHandler {
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
        Ok(json!({
            "result": format!("done-{label}"),
            "themeColor": "#10B981",
            "presentationHints": {
                "chipTitle": format!("Direct {label}"),
                "themeColor": "#10B981"
            }
        }))
    }
}

async fn phase_engine_surface() -> (EngineHostHandle, ResolvedPrimitiveSurface) {
    let engine_host = EngineHostHandle::new_in_memory().expect("engine host");
    let function_id = FunctionId::new("tool::phase_lifecycle").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("tool").expect("worker id"),
        "Phase lifecycle test".to_owned(),
        FunctionVisibility::Public,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low);
    engine_host
        .register_function(function.clone(), Arc::new(DelayedToolHandler))
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "phase_lifecycle".to_owned(),
        PrimitiveExecutionTarget {
            model_tool_id: "phase_lifecycle".to_owned(),
            function_id,
            function,
        },
    );
    (
        engine_host,
        ResolvedPrimitiveSurface {
            tools: Vec::new(),
            targets_by_name,
            snapshot: Default::default(),
        },
    )
}

fn context_manager_for_workdir(working_directory: &str) -> ContextManager {
    ContextManager::new(ContextManagerConfig {
        system_prompt: Some("system".to_owned()),
        working_directory: Some(working_directory.to_owned()),
        compaction: CompactionConfig::default(),
    })
}

fn stream_result_with_invocations(tool_invocations: Vec<ToolInvocationDraft>) -> StreamResult {
    StreamResult {
        message: AssistantMessage {
            content: Vec::new(),
            token_usage: None,
        },
        tool_invocations,
        stop_reason: "tool_invocation".to_owned(),
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

#[tokio::test]
async fn direct_tool_provider_result_is_stable_after_reconstruction() {
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
    let invocation_id = "call-direct-result".to_owned();
    let arguments = Map::from_iter([("filter".to_owned(), json!("recent"))]);
    let stream_result = stream_result_with_invocations(vec![ToolInvocationDraft::new(
        invocation_id.clone(),
        "phase_lifecycle",
        arguments.clone(),
    )]);

    h.persister
        .append_with_runtime_sequence(
            &h.session_id,
            EventType::MessageAssistant,
            json!({
                "content": [{
                    "type": "tool_invocation",
                    "id": invocation_id,
                    "name": "phase_lifecycle",
                    "arguments": arguments,
                }],
                "turn": 1,
            }),
            Some(&h.counter),
        )
        .expect("persist assistant invocation");

    let outcome = execute_tool_phase(ToolPhaseParams {
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
        invocation_abort_registry: h.invocation_abort_registry.as_ref(),
        engine_host: &engine_host,
        run_id: Some("run-direct-result"),
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        nested_tool_ordinals: &Default::default(),
    })
    .await;
    assert_eq!(outcome.tool_invocations_executed, 1);

    let live_content = context_manager
        .messages_slice()
        .iter()
        .find_map(|message| match message {
            Message::ToolResult {
                invocation_id: id,
                content: ToolResultMessageContent::Text(content),
                ..
            } if id == &invocation_id => Some(content.clone()),
            _ => None,
        })
        .expect("live provider result");
    assert_eq!(
        serde_json::from_str::<Value>(&live_content).expect("typed provider value")["result"],
        "done-unknown"
    );

    let completed = persisted_rows(&h.store, &h.session_id, "tool.invocation.completed");
    assert_eq!(completed.len(), 1);
    let completed_payload: Value =
        serde_json::from_str(&completed[0].payload).expect("completed event payload");
    let persisted_content = completed_payload
        .get("modelContextContent")
        .or_else(|| completed_payload.get("content"))
        .and_then(Value::as_str)
        .expect("persisted provider content");
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
            Message::ToolResult {
                invocation_id: id,
                content: ToolResultMessageContent::Text(content),
                ..
            } if id == &invocation_id => Some(content),
            _ => None,
        })
        .expect("reconstructed provider result");
    assert_eq!(reconstructed_content.as_bytes(), live_content.as_bytes());
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
        ToolInvocationDraft::new("call-slow", "phase_lifecycle", {
            let mut args = Map::new();
            args.insert("traceId".to_owned(), json!("slow"));
            args
        }),
        ToolInvocationDraft::new("call-fast", "phase_lifecycle", {
            let mut args = Map::new();
            args.insert("traceId".to_owned(), json!("fast"));
            args
        }),
    ]);

    let outcome = execute_tool_phase(ToolPhaseParams {
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
        invocation_abort_registry: h.invocation_abort_registry.as_ref(),
        engine_host: &engine_host,
        run_id: Some("run-phase"),
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        nested_tool_ordinals: &Default::default(),
    })
    .await;

    assert_eq!(outcome.tool_invocations_executed, 2);
    let events = collect_broadcasts(&mut h.rx, 5).await;
    let lifecycle: Vec<&TronEvent> = events
        .iter()
        .filter(|event| {
            matches!(
                event,
                TronEvent::ToolInvocationStarted { .. } | TronEvent::ToolInvocationCompleted { .. }
            )
        })
        .collect();
    assert_eq!(lifecycle.len(), 4, "no duplicate lifecycle events");
    assert!(matches!(
        lifecycle[0],
        TronEvent::ToolInvocationStarted { .. }
    ));
    assert!(matches!(
        lifecycle[1],
        TronEvent::ToolInvocationStarted { .. }
    ));
    assert!(matches!(
        lifecycle[2],
        TronEvent::ToolInvocationCompleted { .. }
    ));

    let persisted_starts = persisted_rows(&h.store, &h.session_id, "tool.invocation.started");
    let persisted_completions =
        persisted_rows(&h.store, &h.session_id, "tool.invocation.completed");
    assert_eq!(persisted_starts.len(), 2);
    assert_eq!(persisted_completions.len(), 2);

    let live_start_sequences: Vec<i64> = lifecycle
        .iter()
        .filter_map(|event| match event {
            TronEvent::ToolInvocationStarted { .. } => event.sequence(),
            _ => None,
        })
        .collect();
    let persisted_start_sequences: Vec<i64> =
        persisted_starts.iter().map(|row| row.sequence).collect();
    assert_eq!(live_start_sequences, persisted_start_sequences);

    let live_completion_sequences: Vec<i64> = lifecycle
        .iter()
        .filter_map(|event| match event {
            TronEvent::ToolInvocationCompleted { .. } => event.sequence(),
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
    let live_completion_ids = lifecycle
        .iter()
        .filter_map(|event| match event {
            TronEvent::ToolInvocationCompleted { invocation_id, .. } => {
                Some(invocation_id.as_str())
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(
        live_completion_ids,
        vec!["call-slow", "call-fast"],
        "completion broadcasts preserve provider invocation order"
    );
    let persisted_completion_payloads = h
        .store
        .resolve_event_payloads(&persisted_completions)
        .expect("resolve completion payloads");
    assert_eq!(
        persisted_completion_payloads
            .iter()
            .map(|payload| payload["invocationId"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["call-slow", "call-fast"],
        "completion rows preserve provider invocation order"
    );

    let started = lifecycle
        .iter()
        .find_map(|event| match event {
            TronEvent::ToolInvocationStarted {
                invocation_id,
                tool_name,
                arguments,
                tool_identity,
                ..
            } if invocation_id == "call-slow" => Some((tool_name, arguments, tool_identity)),
            _ => None,
        })
        .expect("slow started event");
    assert_eq!(started.0, "phase_lifecycle");
    assert_eq!(started.1.as_ref().unwrap()["traceId"], "slow");
    assert_eq!(started.2.trace_id, None);

    let completed = lifecycle
        .iter()
        .find_map(|event| match event {
            TronEvent::ToolInvocationCompleted {
                invocation_id,
                result,
                tool_identity,
                ..
            } if invocation_id == "call-fast" => Some((result, tool_identity)),
            _ => None,
        })
        .expect("fast completed event");
    assert_eq!(completed.0.as_ref().unwrap().is_error, Some(false));
    assert_eq!(completed.1.theme_color.as_deref(), Some("#10B981"));
}

#[tokio::test]
async fn parent_cancellation_during_parallel_tool_batch_marks_active_turn_interrupted() {
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
    let cancel_task_token = cancel.clone();
    let cancel_task = tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        cancel_task_token.cancel();
    });
    let stream_result = stream_result_with_invocations(vec![ToolInvocationDraft::new(
        "call-cancelled",
        "phase_lifecycle",
        Map::from_iter([("traceId".to_owned(), json!("slow"))]),
    )]);

    let outcome = execute_tool_phase(ToolPhaseParams {
        turn: 8,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: &h.session_id,
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: h.invocation_abort_registry.as_ref(),
        engine_host: &engine_host,
        run_id: Some("run-cancelled-wave"),
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        nested_tool_ordinals: &Default::default(),
    })
    .await;
    cancel_task.await.unwrap();

    assert!(outcome.interrupted);
    assert_eq!(outcome.tool_invocations_executed, 1);
    assert_eq!(
        persisted_rows(
            &h.store,
            &h.session_id,
            EventType::ToolInvocationCompleted.as_str(),
        )
        .len(),
        1
    );
}

#[tokio::test]
async fn phase_does_not_broadcast_starts_when_start_persistence_fails() {
    let mut h = phase_persistence_harness().await;
    let (engine_host, surface) = phase_engine_surface().await;
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = tempdir.path().to_str().expect("utf8 tempdir");
    let mut context_manager = context_manager_for_workdir(working_directory);
    let cancel = CancellationToken::new();
    let stream_result = stream_result_with_invocations(vec![ToolInvocationDraft::new(
        "call-1",
        "phase_lifecycle",
        Map::new(),
    )]);

    let outcome = execute_tool_phase(ToolPhaseParams {
        turn: 1,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: "missing-session",
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: h.invocation_abort_registry.as_ref(),
        engine_host: &engine_host,
        run_id: Some("run-phase"),
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        nested_tool_ordinals: &Default::default(),
    })
    .await;

    assert_eq!(outcome.tool_invocations_executed, 0);
    assert!(outcome.error.is_some());
    let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
    assert!(
        result.is_err(),
        "no live start should broadcast when start persistence fails: {result:?}"
    );
}

#[tokio::test]
async fn completion_batch_failure_atomically_terminalizes_every_durable_start() {
    let mut h = phase_persistence_harness_with_trigger(Some(
        "CREATE TRIGGER fail_second_tool_completion
         BEFORE INSERT ON events
         WHEN NEW.type = 'tool.invocation.completed'
          AND NEW.invocation_id = 'call-fast'
          AND json_extract(NEW.payload, '$.details.status') IS NULL
         BEGIN
           SELECT RAISE(FAIL, 'forced second tool completion failure');
         END;",
    ))
    .await;
    let (engine_host, surface) = phase_engine_surface().await;
    let tempdir = tempfile::tempdir().expect("working directory");
    let working_directory = tempdir.path().to_str().expect("utf8 tempdir");
    let mut context_manager = context_manager_for_workdir(working_directory);
    let cancel = CancellationToken::new();
    let stream_result = stream_result_with_invocations(vec![
        ToolInvocationDraft::new(
            "call-slow",
            "phase_lifecycle",
            Map::from_iter([("traceId".to_owned(), json!("slow"))]),
        ),
        ToolInvocationDraft::new(
            "call-fast",
            "phase_lifecycle",
            Map::from_iter([("traceId".to_owned(), json!("fast"))]),
        ),
    ]);

    let outcome = execute_tool_phase(ToolPhaseParams {
        turn: 9,
        stream_result: &stream_result,
        context_manager: &mut context_manager,
        primitive_surface: &surface,
        session_id: &h.session_id,
        emitter: &h.emitter,
        cancel: &cancel,
        workspace_id: None,
        persister: Some(&h.persister),
        sequence_counter: Some(&h.counter),
        invocation_abort_registry: h.invocation_abort_registry.as_ref(),
        engine_host: &engine_host,
        run_id: Some("run-completion-rollback"),
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        nested_tool_ordinals: &Default::default(),
    })
    .await;

    assert!(outcome.error.is_some(), "batch failure must fail the phase");
    assert_eq!(
        persisted_rows(
            &h.store,
            &h.session_id,
            EventType::ToolInvocationStarted.as_str(),
        )
        .len(),
        2,
        "the already-committed start batch remains durable"
    );
    let completions = persisted_rows(
        &h.store,
        &h.session_id,
        EventType::ToolInvocationCompleted.as_str(),
    );
    assert_eq!(
        completions.len(),
        2,
        "the fail-closed repair must terminalize the full requested set"
    );
    let completion_payloads = h
        .store
        .resolve_event_payloads(&completions)
        .expect("resolve repaired completions");
    assert_eq!(
        completion_payloads
            .iter()
            .map(|payload| payload["invocationId"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["call-slow", "call-fast"],
        "repair rows preserve provider request order"
    );
    assert!(
        completion_payloads.iter().all(|payload| {
            payload["details"]["status"] == json!("persistence_failed")
                && payload["details"]["code"] == json!("TOOL_COMPLETION_PERSISTENCE_FAILED")
                && payload["details"]["executed"] == json!(true)
                && payload["isError"] == json!(true)
                && !payload["content"]
                    .as_str()
                    .is_some_and(|content| content.starts_with("done-"))
        }),
        "the failed normal batch must leave no partial success completion"
    );
    let started_ids = persisted_rows(
        &h.store,
        &h.session_id,
        EventType::ToolInvocationStarted.as_str(),
    )
    .into_iter()
    .map(|row| row.invocation_id.expect("start invocation id"))
    .collect::<Vec<_>>();
    let completed_ids = completions
        .iter()
        .map(|row| row.invocation_id.clone().expect("completion invocation id"))
        .collect::<Vec<_>>();
    assert_eq!(
        completed_ids, started_ids,
        "no durable start may remain without an immediate terminal row"
    );

    let mut live_completions = Vec::new();
    while let Ok(event) = h.rx.try_recv() {
        if let TronEvent::ToolInvocationCompleted { invocation_id, .. } = event {
            live_completions.push(invocation_id);
        }
    }
    assert_eq!(
        live_completions,
        vec!["call-slow", "call-fast"],
        "only the committed fail-closed terminal batch broadcasts"
    );
}
