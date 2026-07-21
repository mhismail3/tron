use super::*;

use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::Mutex;
use serde_json::{Map, Value, json};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::primitive_surface::{
    ExecutionMode, PrimitiveExecutionTarget, ResolvedPrimitiveSurface,
};
use crate::engine::{
    ActorId, EffectClass, FunctionDefinition, FunctionId, RiskLevel, VisibilityScope,
    WorkerDefinition, WorkerId, WorkerKind,
};
use crate::shared::protocol::messages::CapabilityInvocationDraft;
use crate::shared::server::failure::{CAPABILITY_PRIMITIVE_NOT_FOUND, RUNTIME_CANCELLED};

#[derive(Clone)]
struct CapturingDirectHandler {
    captured: Arc<Mutex<Option<Invocation>>>,
}

#[async_trait]
impl crate::engine::InProcessFunctionHandler for CapturingDirectHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        *self.captured.lock() = Some(invocation);
        Ok(json!({"typed": "ok"}))
    }
}

fn empty_surface() -> ResolvedPrimitiveSurface {
    ResolvedPrimitiveSurface {
        capabilities: Vec::new(),
        targets_by_name: BTreeMap::new(),
        turn_stopping_capabilities: HashSet::new(),
        snapshot: Default::default(),
    }
}

fn execution_context<'a>(
    surface: &'a ResolvedPrimitiveSurface,
    emitter: &'a Arc<EventEmitter>,
    cancel: &'a CancellationToken,
    aborts: &'a InvocationAbortRegistry,
    host: &'a EngineHostHandle,
) -> CapabilityInvocationExecutionContext<'a> {
    CapabilityInvocationExecutionContext {
        primitive_surface: surface,
        emitter,
        cancel,
        workspace_id: Some("workspace-test"),
        sequence_counter: None,
        emit_lifecycle_events: true,
        turn: 4,
        invocation_abort_registry: aborts,
        engine_host: host,
        run_id: Some("run-test"),
        provider_type: "test-provider",
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
    }
}

#[test]
fn transient_capability_result_copy_is_redacted_without_mutating_provider_result() {
    let token = "trwh_0123456789abcdef0123456789abcdef";
    let result = CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::text(format!("credential: {token}")),
            CapabilityResultContent::image("image-data", "image/png"),
        ]),
        details: Some(json!({"token": token, "status": "active"})),
        is_error: None,
        stop_turn: None,
    };

    let redacted = redacted_capability_result(&result);

    assert!(!serde_json::to_string(&redacted).unwrap().contains(token));
    assert_eq!(redacted.details.as_ref().unwrap()["token"], "****");
    assert!(serde_json::to_string(&result).unwrap().contains(token));
}

#[tokio::test]
async fn unknown_direct_tool_fails_before_engine_execution() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    let surface = empty_surface();
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let aborts = InvocationAbortRegistry::new();
    let context = execution_context(&surface, &emitter, &cancel, &aborts, &host);
    let call = CapabilityInvocationDraft::new("call-unknown", "missing_tool", Map::new());

    let result = execute_capability_invocation(&call, "session-test", "/tmp", &context).await;

    assert_eq!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        CAPABILITY_PRIMITIVE_NOT_FOUND
    );
    assert!(result.result.is_error.unwrap_or(false));
}

#[tokio::test]
async fn direct_tool_uses_typed_payload_and_trusted_local_context() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.register_worker(
        WorkerDefinition::new(
            WorkerId::new("worker_kernel").unwrap(),
            WorkerKind::InProcess,
            ActorId::new("worker-kernel-owner").unwrap(),
        )
        .with_namespace_claim("worker_kernel"),
        false,
    )
    .await
    .unwrap();
    let function_id = FunctionId::new("worker_kernel::direct_test").unwrap();
    let mut function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("worker_kernel").unwrap(),
        "Direct typed test function",
        VisibilityScope::System,
        EffectClass::PureRead,
    )
    .with_risk(RiskLevel::Low)
    .with_request_schema(json!({
        "type":"object",
        "required":["value"],
        "properties":{"value":{"type":"string"}},
        "additionalProperties":false
    }));
    let captured = Arc::new(Mutex::new(None));
    let revision = host
        .register_function(
            function.clone(),
            Some(Arc::new(CapturingDirectHandler {
                captured: Arc::clone(&captured),
            })),
            false,
        )
        .await
        .unwrap();
    function.revision = revision;
    let target = PrimitiveExecutionTarget {
        model_capability_id: "direct_test".to_owned(),
        function_id,
        function,
        stops_turn: false,
        execution_mode: ExecutionMode::Parallel,
        trusted_local: true,
    };
    let surface = ResolvedPrimitiveSurface {
        capabilities: Vec::new(),
        targets_by_name: BTreeMap::from([("direct_test".to_owned(), target)]),
        turn_stopping_capabilities: HashSet::new(),
        snapshot: crate::domains::worker_kernel::EngineSurfaceSnapshot {
            catalog_revision: 17,
            surface_hash: "surface-hash-test".to_owned(),
            ..Default::default()
        },
    };
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let aborts = InvocationAbortRegistry::new();
    let trace = TraceId::new("direct-trace").unwrap();
    let parent = InvocationId::new("parent-invocation").unwrap();
    let mut context = execution_context(&surface, &emitter, &cancel, &aborts, &host);
    context.trace_id = Some(&trace);
    context.parent_invocation_id = Some(&parent);
    context.worker_causal_depth = 7;
    let call = CapabilityInvocationDraft::new(
        "direct-call",
        "direct_test",
        Map::from_iter([("value".to_owned(), json!("hello"))]),
    );

    let result = execute_capability_invocation(&call, "direct-session", "/tmp", &context).await;

    assert_eq!(result.result.is_error, None);
    assert_eq!(result.result.details.as_ref().unwrap()["typed"], "ok");
    let invocation = captured.lock().clone().expect("captured direct invocation");
    assert_eq!(invocation.payload, json!({"value":"hello"}));
    assert!(invocation.causal_context.is_trusted_local());
    assert_eq!(invocation.causal_context.trace_id, trace);
    assert_eq!(invocation.causal_context.parent_invocation_id, Some(parent));
    assert_eq!(
        invocation
            .causal_context
            .runtime_metadata
            .get(crate::engine::RUNTIME_METADATA_TRIGGER_DEPTH)
            .map(String::as_str),
        Some("7")
    );
    assert_eq!(
        invocation
            .causal_context
            .runtime_metadata(crate::engine::RUNTIME_METADATA_EXPECTED_FUNCTION_REVISION),
        Some("1")
    );
    assert_eq!(
        invocation
            .causal_context
            .runtime_metadata(crate::engine::RUNTIME_METADATA_ADVERTISED_CATALOG_REVISION),
        Some("17")
    );
    assert_eq!(
        invocation
            .causal_context
            .runtime_metadata(crate::engine::RUNTIME_METADATA_SURFACE_HASH),
        Some("surface-hash-test")
    );
    assert!(
        invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .is_some_and(|key| key.starts_with("model-tool:"))
    );
}

#[tokio::test]
async fn cancelled_direct_tool_returns_the_canonical_cancelled_failure() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    let surface = empty_surface();
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    cancel.cancel();
    let aborts = InvocationAbortRegistry::new();
    let context = execution_context(&surface, &emitter, &cancel, &aborts, &host);
    let call = CapabilityInvocationDraft::new("cancelled", "missing_tool", Map::new());

    let result = execute_capability_invocation(&call, "session-test", "/tmp", &context).await;

    // Resolution precedes execution cancellation, so an absent tool remains a
    // not-found failure and does not create an abort-registry entry.
    assert_eq!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        CAPABILITY_PRIMITIVE_NOT_FOUND
    );
    assert!(aborts.is_empty());
    assert_ne!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        RUNTIME_CANCELLED
    );
}
