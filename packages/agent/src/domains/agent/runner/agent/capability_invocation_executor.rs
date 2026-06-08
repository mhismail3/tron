//! Model capability executor for the primitive `execute` surface.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::agent::primitive_surface::{
    PrimitiveExecutionTarget, ResolvedPrimitiveSurface,
};
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::{
    InvocationAbortGuard, InvocationAbortRegistry,
};
use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;
use crate::engine::invocation::model::{
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation,
    InvocationId, TraceId,
};
use crate::shared::protocol::events::{BaseEvent, CapabilityEventIdentity, TronEvent};
use crate::shared::protocol::messages::CapabilityInvocationDraft;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, instrument};

fn duration_ceil_ms(d: Duration) -> u64 {
    let micros = d.as_micros();
    if micros == 0 {
        return 0;
    }
    micros.div_ceil(1000) as u64
}

fn traced_base(
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> BaseEvent {
    BaseEvent::now(session_id).with_trace_context(
        trace_id.map(|id| id.as_str().to_owned()),
        parent_invocation_id.map(|id| id.as_str().to_owned()),
    )
}

fn operation_name_from_value(value: &Value) -> Option<String> {
    ["operationName", "operation"].iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|operation| !operation.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn primitive_capability_identity(
    model_primitive_name: &str,
    arguments: &Value,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> CapabilityEventIdentity {
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
        operation_name: operation_name_from_value(arguments),
        trace_id: trace_id.map(|id| id.as_str().to_owned()),
        root_invocation_id: parent_invocation_id.map(|id| id.as_str().to_owned()),
        ..CapabilityEventIdentity::default()
    }
}

fn capability_identity_from_result(
    model_primitive_name: &str,
    base_identity: &CapabilityEventIdentity,
    result: &crate::shared::protocol::model_capabilities::CapabilityResult,
) -> CapabilityEventIdentity {
    let Some(details) = result.details.as_ref() else {
        return base_identity.clone();
    };
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
        operation_name: operation_name_from_value(details)
            .or_else(|| base_identity.operation_name.clone()),
        trace_id: details
            .get("traceId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.trace_id.clone()),
        root_invocation_id: details
            .get("rootInvocationId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.root_invocation_id.clone()),
        theme_color: details
            .get("themeColor")
            .and_then(Value::as_str)
            .or_else(|| {
                details
                    .get("presentationHints")
                    .and_then(|hints| hints.get("themeColor"))
                    .and_then(Value::as_str)
            })
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.theme_color.clone()),
        presentation_hints: details
            .get("presentationHints")
            .cloned()
            .or_else(|| base_identity.presentation_hints.clone()),
        ..base_identity.clone()
    }
}

pub struct CapabilityInvocationExecutionContext<'a> {
    pub primitive_surface: &'a ResolvedPrimitiveSurface,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub workspace_id: Option<&'a str>,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub turn: i64,
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    pub engine_host: Option<&'a EngineHostHandle>,
    pub run_id: Option<&'a str>,
    pub provider_type: &'a str,
    pub trace_id: Option<&'a TraceId>,
    pub parent_invocation_id: Option<&'a InvocationId>,
}

#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(model_primitive_name = capability_invocation.name, session_id))]
pub async fn execute_capability_invocation(
    capability_invocation: &CapabilityInvocationDraft,
    session_id: &str,
    working_directory: &str,
    ctx: &CapabilityInvocationExecutionContext<'_>,
) -> CapabilityInvocationExecutionResult {
    let start = Instant::now();
    let invocation_id = capability_invocation.id.clone();
    let model_primitive_name = capability_invocation.name.clone();

    let Some(engine_target) = ctx
        .primitive_surface
        .targets_by_name
        .get(&model_primitive_name)
    else {
        error!(model_primitive_name, "capability primitive not found");
        return CapabilityInvocationExecutionResult {
            result: crate::shared::protocol::model_capabilities::error_result(format!(
                "Capability primitive not found: {model_primitive_name}"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            stops_turn: false,
        };
    };

    let stops_turn = engine_target.stops_turn;
    let effective_args = Value::Object(capability_invocation.arguments.clone());
    let primitive_identity = primitive_capability_identity(
        &model_primitive_name,
        &effective_args,
        ctx.trace_id,
        ctx.parent_invocation_id,
    );

    let started = TronEvent::CapabilityInvocationStarted {
        base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
        invocation_id: invocation_id.clone(),
        model_primitive_name: model_primitive_name.clone(),
        arguments: effective_args.as_object().cloned(),
        capability_identity: primitive_identity.clone(),
    };
    emit(ctx, started);
    debug!(
        model_primitive_name,
        invocation_id, session_id, "capability invocation started"
    );

    let (per_invocation_cancel, _abort_guard) = match ctx.invocation_abort_registry {
        Some(registry) => {
            let child = registry.register(session_id, &invocation_id, ctx.cancel);
            let guard = InvocationAbortGuard::new(Arc::clone(registry), session_id, &invocation_id);
            (child, Some(guard))
        }
        None => (ctx.cancel.clone(), None),
    };

    let capability_result = if per_invocation_cancel.is_cancelled() {
        crate::shared::protocol::model_capabilities::error_result("Operation cancelled")
    } else if let Some(engine_host) = ctx.engine_host {
        execute_capability_primitive_via_engine(
            engine_host,
            engine_target,
            &model_primitive_name,
            &invocation_id,
            session_id,
            working_directory,
            ctx.workspace_id,
            ctx.turn,
            ctx.run_id,
            ctx.provider_type,
            ctx.trace_id,
            ctx.parent_invocation_id,
            effective_args,
        )
        .await
    } else {
        return CapabilityInvocationExecutionResult {
            result: crate::shared::protocol::model_capabilities::error_result(format!(
                "Engine host is required to execute capability primitive '{model_primitive_name}'"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            stops_turn,
        };
    };

    let result_stops_turn = capability_result.stop_turn.unwrap_or(false);
    let duration_ms = duration_ceil_ms(start.elapsed());
    let resolved_identity = capability_identity_from_result(
        &model_primitive_name,
        &primitive_identity,
        &capability_result,
    );

    metrics::counter!("capability_invocations_total", "capability" => model_primitive_name.clone())
        .increment(1);
    metrics::histogram!("capability_invocation_duration_seconds", "capability" => model_primitive_name.clone())
        .record(start.elapsed().as_secs_f64());

    let completed = TronEvent::CapabilityInvocationCompleted {
        base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
        invocation_id: invocation_id.clone(),
        model_primitive_name: model_primitive_name.clone(),
        duration: duration_ms,
        is_error: capability_result.is_error,
        result: Some(capability_result.clone()),
        capability_identity: resolved_identity,
    };
    emit(ctx, completed);
    debug!(capability = %model_primitive_name, duration_ms, "capability invocation completed");

    CapabilityInvocationExecutionResult {
        result: capability_result,
        duration_ms,
        stops_turn: stops_turn || result_stops_turn,
    }
}

fn emit(ctx: &CapabilityInvocationExecutionContext<'_>, event: TronEvent) {
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(event, counter);
    } else {
        let _ = ctx.emitter.emit(event);
    }
}

fn with_agent_working_directory_metadata(
    context: CausalContext,
    working_directory: &str,
) -> CausalContext {
    context.with_runtime_metadata(
        RUNTIME_METADATA_WORKING_DIRECTORY,
        working_directory.to_owned(),
    )
}

#[allow(clippy::too_many_arguments)]
async fn execute_capability_primitive_via_engine(
    engine_host: &EngineHostHandle,
    target: &PrimitiveExecutionTarget,
    model_primitive_name: &str,
    invocation_id: &str,
    session_id: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    turn: i64,
    run_id: Option<&str>,
    provider_type: &str,
    inherited_trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    effective_args: Value,
) -> crate::shared::protocol::model_capabilities::CapabilityResult {
    let idempotency_key = model_capability_invocation_idempotency_key(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        &effective_args,
    );
    let actor_id = match ActorId::new(format!("agent:{session_id}")) {
        Ok(id) => id,
        Err(error) => {
            return crate::shared::protocol::model_capabilities::error_result(error.to_string());
        }
    };
    let grant_id = match AuthorityGrantId::new("agent-capability-runtime") {
        Ok(id) => id,
        Err(error) => {
            return crate::shared::protocol::model_capabilities::error_result(error.to_string());
        }
    };
    let trace_id = inherited_trace_id
        .cloned()
        .unwrap_or_else(TraceId::generate);
    let mut causal_context = with_agent_working_directory_metadata(
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id),
        working_directory,
    )
    .with_scope("capability.execute")
    .with_runtime_metadata(
        RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
        invocation_id.to_owned(),
    )
    .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, provider_type.to_owned())
    .with_runtime_metadata(
        RUNTIME_METADATA_MODEL_PRIMITIVE_NAME,
        model_primitive_name.to_owned(),
    )
    .with_runtime_metadata(RUNTIME_METADATA_TURN, turn.to_string())
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(idempotency_key);
    if let Some(run_id) = run_id {
        causal_context =
            causal_context.with_runtime_metadata(RUNTIME_METADATA_RUN_ID, run_id.to_owned());
    }
    if let Some(workspace_id) = workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.to_owned());
    }
    if let Some(parent) = parent_invocation_id {
        causal_context = causal_context.with_parent_invocation(parent.clone());
    }
    for scope in &target.function.required_authority.scopes {
        if !causal_context.has_scope(scope) {
            causal_context = causal_context.with_scope(scope.clone());
        }
    }
    let function_id = target.function_id.clone();
    let invocation = Invocation::new_sync(function_id.clone(), effective_args, causal_context);
    let result = engine_host.invoke(invocation).await;

    if let Some(error) = result.error {
        return crate::shared::protocol::model_capabilities::error_result(format!(
            "Engine capability invocation failed for {function_id}: {error}"
        ));
    }
    let Some(value) = result.value else {
        return crate::shared::protocol::model_capabilities::error_result(format!(
            "Engine capability invocation returned no result for {function_id}"
        ));
    };
    serde_json::from_value(value).unwrap_or_else(|error| {
        crate::shared::protocol::model_capabilities::error_result(format!(
            "Engine capability invocation returned invalid capability result for {function_id}: {error}"
        ))
    })
}

#[allow(clippy::too_many_arguments)]
fn stable_capability_invocation_material(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let payload = json!({
        "runId": run_id,
        "sessionId": session_id,
        "turn": turn,
        "providerCallId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "workingDirectory": working_directory,
        "workspaceId": workspace_id,
        "arguments": effective_args
    });
    serde_json::to_string(&payload).unwrap_or_else(|_| {
        format!(
            "{run_id:?}:{session_id}:{turn}:{invocation_id}:{model_primitive_name}:{working_directory}:{workspace_id:?}:{effective_args}",
        )
    })
}

fn model_capability_invocation_idempotency_key(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let material = stable_capability_invocation_material(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        effective_args,
    );
    format!(
        "model-capability-invocation:v1:{}",
        sha256_hex(material.as_bytes())
    )
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
#[path = "capability_invocation_executor/tests.rs"]
mod tests;
