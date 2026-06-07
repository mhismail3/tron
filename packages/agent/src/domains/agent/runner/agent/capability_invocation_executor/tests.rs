use super::*;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::capability_support::implementations::primitive_surface::{
    EngineCapabilityTarget, ResolvedCapabilitySurface, resolve_provider_capabilities,
};
use crate::domains::capability_support::implementations::traits::ExecutionMode;
use crate::engine::{
    AuthorityRequirement, EffectClass, FunctionDefinition, FunctionId, RiskLevel, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::CapabilityResultBody;
use async_trait::async_trait;
use parking_lot::Mutex;
use std::collections::{BTreeMap, HashSet};

fn empty_surface() -> ResolvedCapabilitySurface {
    ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(0),
        capabilities: Vec::new(),
        targets_by_name: BTreeMap::new(),
        all_model_capability_ids: Vec::new(),
        turn_stopping_capabilities: HashSet::new(),
    }
}

#[test]
fn model_primitive_context_carries_trusted_working_directory_metadata() {
    let context = CausalContext::new(
        ActorId::new("agent:s1").expect("actor id"),
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
        TraceId::new("trace").expect("trace id"),
    );

    let context = with_agent_working_directory_metadata(context, "/tmp/session-worktree");

    assert_eq!(
        context.runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY),
        Some("/tmp/session-worktree")
    );
}

fn surface_with_echo() -> ResolvedCapabilitySurface {
    let function_id = FunctionId::new("capability::execute").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Echo".to_owned(),
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"));
    let target = EngineCapabilityTarget {
        model_capability_id: "execute".to_owned(),
        function_id,
        function,
        stops_turn: true,
        is_interactive: false,
        execution_mode: ExecutionMode::Parallel,
    };
    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert("execute".to_owned(), target);
    ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(0),
        capabilities: Vec::new(),
        targets_by_name,
        all_model_capability_ids: vec!["execute".to_owned()],
        turn_stopping_capabilities: HashSet::from(["execute".to_owned()]),
    }
}

fn capability_exec_ctx<'a>(
    surface: &'a ResolvedCapabilitySurface,
    emitter: &'a Arc<EventEmitter>,
    cancel: &'a CancellationToken,
) -> CapabilityInvocationExecutionContext<'a> {
    CapabilityInvocationExecutionContext {
        primitive_surface: surface,
        emitter,
        cancel,
        workspace_id: None,
        sequence_counter: None,
        turn: 1,
        invocation_abort_registry: None,
        engine_host: None,
        run_id: Some("run-1"),
        trace_id: None,
        parent_invocation_id: None,
    }
}

#[tokio::test]
async fn unknown_model_primitive_fails_before_execution() {
    let surface = empty_surface();
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    let call = CapabilityInvocationDraft::new("tc1", "Missing", Default::default());
    let result = execute_capability_invocation(&call, "s1", "/tmp", &ctx).await;
    assert!(result.result.is_error.unwrap_or(false));
}

#[tokio::test]
async fn catalog_target_requires_engine_host_for_execution() {
    let surface = surface_with_echo();
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    let call = CapabilityInvocationDraft::new("tc1", "execute", Default::default());
    let result = execute_capability_invocation(&call, "s1", "/tmp", &ctx).await;
    assert!(result.result.is_error.unwrap_or(false));
    assert!(result.stops_turn);
}

#[tokio::test]
async fn model_capability_invocation_invokes_execute_primitive_through_engine() {
    let server = crate::shared::server::test_support::make_test_context();
    let surface = resolve_provider_capabilities(&server.engine_host, "s1", None)
        .await
        .expect("provider capability surface");
    assert_eq!(surface.all_model_capability_ids, vec!["execute"]);
    assert!(surface.targets_by_name.contains_key("execute"));

    let tempdir = tempfile::tempdir().expect("capability tempdir");
    let file_path = tempdir.path().join("note.txt");
    std::fs::write(&file_path, "hello from engine").expect("write fixture");

    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    ctx.engine_host = Some(&server.engine_host);

    let mut args = serde_json::Map::new();
    args.insert(
        "operation".to_owned(),
        Value::String("file_read".to_owned()),
    );
    args.insert("path".to_owned(), Value::String("note.txt".to_owned()));
    let call = CapabilityInvocationDraft::new("tc1", "execute", args);
    let result = execute_capability_invocation(
        &call,
        "s1",
        tempdir.path().to_str().expect("utf8 tempdir"),
        &ctx,
    )
    .await;

    assert_eq!(result.result.is_error, Some(false));
    match result.result.content {
        CapabilityResultBody::Text(text) => assert!(text.contains("hello from engine")),
        CapabilityResultBody::Blocks(blocks) => {
            let rendered = blocks
                .iter()
                .map(|block| format!("{block:?}"))
                .collect::<Vec<_>>()
                .join("\n");
            assert!(rendered.contains("hello from engine"));
        }
    }
}

#[derive(Clone)]
struct CapturingCapabilityHandler {
    captured: Arc<Mutex<Option<Invocation>>>,
}

#[async_trait]
impl crate::engine::InProcessFunctionHandler for CapturingCapabilityHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        *self.captured.lock() = Some(invocation);
        Ok(json!({"content": "ok"}))
    }
}

#[derive(Clone)]
struct CountingCapabilityHandler {
    captured: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl crate::engine::InProcessFunctionHandler for CountingCapabilityHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        let mut captured = self.captured.lock();
        let count = captured.len() + 1;
        captured.push(invocation);
        Ok(json!({"content": format!("ok-{count}")}))
    }
}

#[derive(Clone)]
struct StopTurnCapabilityHandler;

#[async_trait]
impl crate::engine::InProcessFunctionHandler for StopTurnCapabilityHandler {
    async fn invoke(&self, _invocation: Invocation) -> crate::engine::Result<Value> {
        serde_json::to_value(crate::shared::model_capabilities::CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "approval required",
            )]),
            details: None,
            is_error: Some(true),
            stop_turn: Some(true),
        })
        .map_err(|error| crate::engine::EngineError::HandlerFailed(error.to_string()))
    }
}

#[tokio::test]
async fn engine_capability_result_stop_turn_pauses_runner_even_when_target_is_not_static_stop() {
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

    let function_id = FunctionId::new("capability::stop").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Stop capability invocation".to_owned(),
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"));
    engine_host
        .register_function(
            function.clone(),
            Some(Arc::new(StopTurnCapabilityHandler)),
            false,
        )
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        EngineCapabilityTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            is_interactive: false,
            execution_mode: ExecutionMode::Parallel,
        },
    );
    let surface = ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(42),
        capabilities: Vec::new(),
        targets_by_name,
        all_model_capability_ids: vec!["execute".to_owned()],
        turn_stopping_capabilities: HashSet::new(),
    };
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    ctx.engine_host = Some(&engine_host);

    let call = CapabilityInvocationDraft::new("capability-invocation-1", "execute", {
        let mut args = serde_json::Map::new();
        args.insert("mode".to_owned(), json!("invoke"));
        args
    });
    let result = execute_capability_invocation(&call, "session-1", "/tmp/worktree", &ctx).await;

    assert!(result.result.is_error.unwrap_or(false));
    assert!(result.stops_turn);
}

#[tokio::test]
async fn model_capability_invocation_inherits_agent_trace_parent_and_idempotency() {
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

    let captured = Arc::new(Mutex::new(None));
    let function_id = FunctionId::new("capability::capture").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Capture capability invocation".to_owned(),
        VisibilityScope::System,
        EffectClass::IdempotentWrite,
    )
    .with_risk(RiskLevel::Medium)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"))
    .with_idempotency(crate::engine::IdempotencyContract::caller_session_engine_ledger());
    engine_host
        .register_function(
            function.clone(),
            Some(Arc::new(CapturingCapabilityHandler {
                captured: Arc::clone(&captured),
            })),
            false,
        )
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        EngineCapabilityTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            is_interactive: false,
            execution_mode: ExecutionMode::Parallel,
        },
    );
    let surface = ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(42),
        capabilities: Vec::new(),
        targets_by_name,
        all_model_capability_ids: vec!["execute".to_owned()],
        turn_stopping_capabilities: HashSet::new(),
    };
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    let trace_id = TraceId::new("agent-trace").expect("trace id");
    let parent_invocation_id = InvocationId::new("agent-run-turn").expect("invocation id");
    ctx.engine_host = Some(&engine_host);
    ctx.trace_id = Some(&trace_id);
    ctx.parent_invocation_id = Some(&parent_invocation_id);

    let mut args = serde_json::Map::new();
    args.insert("value".to_owned(), Value::String("hello".to_owned()));
    let call = CapabilityInvocationDraft::new("capability-invocation-1", "execute", args);
    let result = execute_capability_invocation(&call, "session-1", "/tmp/worktree", &ctx).await;

    assert_eq!(result.result.is_error, None);
    let invocation = captured
        .lock()
        .clone()
        .expect("capability invocation should be captured");
    assert_eq!(invocation.causal_context.trace_id, trace_id);
    assert_eq!(
        invocation.causal_context.parent_invocation_id,
        Some(parent_invocation_id)
    );
    let expected_material = stable_capability_invocation_material(
        Some("run-1"),
        "session-1",
        1,
        "capability-invocation-1",
        "execute",
        "/tmp/worktree",
        None,
        &json!({"value": "hello"}),
    );
    let expected_key = format!(
        "model-capability-invocation:v1:{}",
        sha256_hex(expected_material.as_bytes())
    );
    assert_eq!(
        invocation.causal_context.idempotency_key.as_deref(),
        Some(expected_key.as_str())
    );
}

#[tokio::test]
async fn execute_model_primitive_keeps_wrapper_idempotency_provider_call_scoped() {
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

    let captured = Arc::new(Mutex::new(Vec::new()));
    let function_id = FunctionId::new("capability::capture").expect("function id");
    let function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("capability").expect("worker id"),
        "Capture capability invocation".to_owned(),
        VisibilityScope::System,
        EffectClass::IdempotentWrite,
    )
    .with_risk(RiskLevel::Medium)
    .with_required_authority(AuthorityRequirement::scope("capability.execute"))
    .with_idempotency(crate::engine::IdempotencyContract::caller_session_engine_ledger());
    engine_host
        .register_function(
            function.clone(),
            Some(Arc::new(CountingCapabilityHandler {
                captured: Arc::clone(&captured),
            })),
            false,
        )
        .await
        .expect("register function");

    let mut targets_by_name = BTreeMap::new();
    let _ = targets_by_name.insert(
        "execute".to_owned(),
        EngineCapabilityTarget {
            model_capability_id: "execute".to_owned(),
            function_id,
            function,
            stops_turn: false,
            is_interactive: false,
            execution_mode: ExecutionMode::Parallel,
        },
    );
    let surface = ResolvedCapabilitySurface {
        catalog_revision: crate::engine::CatalogRevision(42),
        capabilities: Vec::new(),
        targets_by_name,
        all_model_capability_ids: vec!["execute".to_owned()],
        turn_stopping_capabilities: HashSet::new(),
    };
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    ctx.engine_host = Some(&engine_host);

    let payload = json!({
        "intent": "read a file",
        "target": "filesystem::read_file",
        "arguments": {"path": "README.md"},
        "idempotencyKey": "manual-read-file-explicit-001"
    });
    let first_call =
        CapabilityInvocationDraft::new("provider-call-id-1", "execute", payload_object(&payload));
    let mut replay_payload = payload.clone();
    replay_payload["reason"] = json!("same target action requested from a later model turn");
    let second_call = CapabilityInvocationDraft::new(
        "provider-call-id-2",
        "execute",
        payload_object(&replay_payload),
    );
    let first_result =
        execute_capability_invocation(&first_call, "session-1", "/tmp/worktree", &ctx).await;
    let second_result =
        execute_capability_invocation(&second_call, "session-1", "/tmp/worktree", &ctx).await;

    assert_eq!(first_result.result.is_error, None);
    assert_eq!(second_result.result.is_error, None);
    let captured = captured.lock().clone();
    assert_eq!(
        captured.len(),
        2,
        "target idempotencyKey must not become the model-wrapper key; replay belongs to the target capability"
    );
    let first_expected_key = model_capability_invocation_idempotency_key(
        Some("run-1"),
        "session-1",
        1,
        "provider-call-id-1",
        "execute",
        "/tmp/worktree",
        None,
        &payload,
    );
    let second_expected_key = model_capability_invocation_idempotency_key(
        Some("run-1"),
        "session-1",
        1,
        "provider-call-id-2",
        "execute",
        "/tmp/worktree",
        None,
        &replay_payload,
    );
    assert_ne!(first_expected_key, second_expected_key);
    assert_eq!(
        captured[0].causal_context.idempotency_key.as_deref(),
        Some(first_expected_key.as_str())
    );
    assert_eq!(
        captured[1].causal_context.idempotency_key.as_deref(),
        Some(second_expected_key.as_str())
    );
}

fn payload_object(value: &Value) -> serde_json::Map<String, Value> {
    value.as_object().expect("payload object").clone()
}

#[test]
fn stable_capability_invocation_material_changes_with_arguments() {
    let a = stable_capability_invocation_material(
        Some("run"),
        "s1",
        1,
        "tc1",
        "Echo",
        "/tmp",
        None,
        &json!({"a":1}),
    );
    let b = stable_capability_invocation_material(
        Some("run"),
        "s1",
        1,
        "tc1",
        "Echo",
        "/tmp",
        None,
        &json!({"a":2}),
    );
    assert_ne!(sha256_hex(a.as_bytes()), sha256_hex(b.as_bytes()));
}
