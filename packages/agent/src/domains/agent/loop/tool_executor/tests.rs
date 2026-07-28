use super::*;

use std::collections::BTreeMap;
use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::Mutex;
use serde_json::{Map, Value, json};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::surface::{PrimitiveExecutionTarget, ResolvedPrimitiveSurface};
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionId, FunctionVisibility, RiskLevel, WorkerId,
};
use crate::shared::protocol::messages::ToolInvocationDraft;
use crate::shared::server::failure::{RUNTIME_CANCELLED, TOOL_PRIMITIVE_NOT_FOUND};

#[test]
fn nested_tool_idempotency_survives_worker_session_recovery() {
    let arguments = json!({"query":"same durable child"});
    let first = direct_tool_idempotency_key(
        Some("run-before-restart"),
        "session-before-restart",
        2,
        "provider-call-before-restart",
        "worker_research_search",
        Some("workspace-1"),
        Some("worker_run_parent"),
        &arguments,
    );
    let recovered = direct_tool_idempotency_key(
        Some("run-after-restart"),
        "session-after-restart",
        2,
        "provider-call-after-restart",
        "worker_research_search",
        Some("workspace-1"),
        Some("worker_run_parent"),
        &arguments,
    );

    assert_eq!(first, recovered);
    assert_ne!(
        first,
        direct_tool_idempotency_key(
            Some("run-after-restart"),
            "session-after-restart",
            3,
            "provider-call-after-restart",
            "worker_research_search",
            Some("workspace-1"),
            Some("worker_run_parent"),
            &arguments,
        )
    );
    assert_ne!(
        first,
        direct_tool_idempotency_key(
            Some("run-after-restart"),
            "session-after-restart",
            2,
            "provider-call-after-restart",
            "worker_research_search",
            Some("workspace-1"),
            Some("worker_run_other_parent"),
            &arguments,
        )
    );
}

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
        tools: Vec::new(),
        targets_by_name: BTreeMap::new(),
        snapshot: Default::default(),
    }
}

fn execution_context<'a>(
    surface: &'a ResolvedPrimitiveSurface,
    emitter: &'a Arc<EventEmitter>,
    cancel: &'a CancellationToken,
    aborts: &'a InvocationAbortRegistry,
    host: &'a EngineHostHandle,
) -> ToolExecutionContext<'a> {
    ToolExecutionContext {
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
        trace_id: None,
        parent_invocation_id: None,
        worker_causal_depth: 0,
        origin_worker_id: None,
        origin_worker_invocation_id: None,
        origin_worker_tool_ordinal: None,
    }
}

#[test]
fn transient_tool_result_copy_is_redacted_without_mutating_provider_result() {
    let token = "trwh_0123456789abcdef0123456789abcdef";
    let result = ToolResult {
        content: ToolResultBody::Blocks(vec![
            ToolResultContent::text(format!("credential: {token}")),
            ToolResultContent::image("image-data", "image/png"),
        ]),
        details: Some(json!({"token": token, "status": "active"})),
        is_error: None,
    };

    let redacted = redacted_tool_result(&result);

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
    let call = ToolInvocationDraft::new("call-unknown", "missing_tool", Map::new());

    let result = execute_tool(&call, "session-test", "/tmp", &context).await;

    assert_eq!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        TOOL_PRIMITIVE_NOT_FOUND
    );
    assert!(result.result.is_error.unwrap_or(false));
}

#[tokio::test]
async fn direct_tool_uses_typed_payload_and_agent_context() {
    let host = EngineHostHandle::new_in_memory().unwrap();
    let function_id = FunctionId::new("worker_kernel::direct_test").unwrap();
    let mut function = FunctionDefinition::new(
        function_id.clone(),
        WorkerId::new("worker_kernel").unwrap(),
        "Direct typed test function",
        FunctionVisibility::Public,
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
            Arc::new(CapturingDirectHandler {
                captured: Arc::clone(&captured),
            }),
        )
        .await
        .unwrap();
    function.revision = revision;
    let target = PrimitiveExecutionTarget {
        model_tool_id: "direct_test".to_owned(),
        function_id,
        function,
    };
    let surface = ResolvedPrimitiveSurface {
        tools: Vec::new(),
        targets_by_name: BTreeMap::from([("direct_test".to_owned(), target)]),
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
    let call = ToolInvocationDraft::new(
        "direct-call",
        "direct_test",
        Map::from_iter([("value".to_owned(), json!("hello"))]),
    );

    let result = execute_tool(&call, "direct-session", "/tmp", &context).await;

    assert_eq!(result.result.is_error, None);
    assert_eq!(result.result.details.as_ref().unwrap()["typed"], "ok");
    let invocation = captured.lock().clone().expect("captured direct invocation");
    assert_eq!(invocation.payload, json!({"value":"hello"}));
    assert_eq!(invocation.causal_context.actor_kind, ActorKind::Agent);
    assert_eq!(invocation.causal_context.trace_id, trace);
    assert_eq!(
        invocation.causal_context.parent_invocation_id,
        Some(parent.clone())
    );
    assert_eq!(invocation.causal_context.trigger_depth(), 7);
    assert_eq!(
        invocation.causal_context.advertised_function_revision(),
        Some(crate::engine::FunctionRevision(1))
    );
    assert_eq!(invocation.causal_context.advertised_worker_version(), None);
    assert_eq!(
        invocation.causal_context.model_tool_invocation_id(),
        Some("direct-call")
    );
    assert!(
        invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .is_some_and(|key| key.starts_with("model-tool:"))
    );

    context.origin_worker_id = Some("semantic-router");
    context.origin_worker_invocation_id = Some("worker_run_semantic_router");
    context.origin_worker_tool_ordinal = Some(3);
    let worker_call = ToolInvocationDraft::new(
        "worker-direct-call",
        "direct_test",
        Map::from_iter([("value".to_owned(), json!("from worker"))]),
    );
    let worker_result = execute_tool(&worker_call, "direct-session", "/tmp", &context).await;
    assert_eq!(worker_result.result.is_error, None);
    let invocation = captured.lock().clone().expect("captured worker invocation");
    assert_eq!(invocation.causal_context.actor_kind, ActorKind::Worker);
    assert_eq!(
        invocation.causal_context.actor_id.as_str(),
        "worker:semantic-router"
    );
    assert_eq!(
        invocation.causal_context.origin_worker_invocation_id(),
        Some("worker_run_semantic_router")
    );
    assert_eq!(
        invocation.causal_context.origin_worker_tool_ordinal(),
        Some(3)
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
    let call = ToolInvocationDraft::new("cancelled", "missing_tool", Map::new());

    let result = execute_tool(&call, "session-test", "/tmp", &context).await;

    // Resolution precedes execution cancellation, so an absent tool remains a
    // not-found failure and does not create an abort-registry entry.
    assert_eq!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        TOOL_PRIMITIVE_NOT_FOUND
    );
    assert!(aborts.is_empty());
    assert_ne!(
        result.result.details.as_ref().unwrap()["failure"]["code"],
        RUNTIME_CANCELLED
    );
}
