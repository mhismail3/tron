//! Model capability executor for the primitive `execute` surface.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::{
    InvocationAbortGuard, InvocationAbortRegistry,
};
use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;
use crate::domains::capability_support::implementations::primitive_surface::{
    EngineCapabilityTarget, ResolvedCapabilitySurface,
};
use crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation,
    InvocationId, TraceId,
};
use crate::shared::events::{BaseEvent, CapabilityEventIdentity, TronEvent};
use crate::shared::messages::CapabilityInvocationDraft;
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

fn string_metadata(function: &crate::engine::FunctionDefinition, key: &str) -> Option<String> {
    function
        .metadata
        .get(key)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn presentation_theme_color(function: &crate::engine::FunctionDefinition) -> Option<String> {
    function
        .metadata
        .get("presentationHints")
        .and_then(|value| value.get("themeColor"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn presentation_hints(function: &crate::engine::FunctionDefinition) -> Option<Value> {
    function.metadata.get("presentationHints").cloned()
}

fn primitive_capability_identity(
    model_primitive_name: &str,
    target: &EngineCapabilityTarget,
    catalog_revision: u64,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> CapabilityEventIdentity {
    let function = &target.function;
    let function_id = function.id.as_str().to_owned();
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
        contract_id: string_metadata(function, "contractId").or_else(|| Some(function_id.clone())),
        implementation_id: string_metadata(function, "implementationId")
            .or_else(|| Some(format!("function:{function_id}"))),
        function_id: Some(function_id),
        plugin_id: string_metadata(function, "pluginId"),
        worker_id: Some(function.owner_worker.as_str().to_owned()),
        schema_digest: None,
        catalog_revision: Some(catalog_revision),
        trust_tier: string_metadata(function, "trustTier"),
        risk_level: Some(format!("{:?}", function.risk_level)),
        effect_class: Some(format!("{:?}", function.effect_class)),
        trace_id: trace_id.map(|id| id.as_str().to_owned()),
        root_invocation_id: parent_invocation_id.map(|id| id.as_str().to_owned()),
        binding_decision_id: None,
        theme_color: presentation_theme_color(function),
        presentation_hints: presentation_hints(function),
    }
}

fn capability_identity_from_result(
    model_primitive_name: &str,
    base_identity: &CapabilityEventIdentity,
    result: &crate::shared::model_capabilities::CapabilityResult,
) -> CapabilityEventIdentity {
    let Some(details) = result.details.as_ref() else {
        return base_identity.clone();
    };
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
        function_id: details
            .get("functionId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.function_id.clone()),
        schema_digest: details
            .get("schemaDigest")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.schema_digest.clone()),
        catalog_revision: details
            .get("catalogRevision")
            .and_then(Value::as_u64)
            .or(base_identity.catalog_revision),
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
            .get("presentationHints")
            .and_then(|hints| hints.get("themeColor"))
            .and_then(Value::as_str)
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
    pub primitive_surface: &'a ResolvedCapabilitySurface,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub workspace_id: Option<&'a str>,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub turn: i64,
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    pub engine_host: Option<&'a EngineHostHandle>,
    pub run_id: Option<&'a str>,
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
            invocation_id,
            result: crate::shared::model_capabilities::error_result(format!(
                "Capability primitive not found: {model_primitive_name}"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            stops_turn: false,
            is_interactive: false,
        };
    };

    let stops_turn = engine_target.stops_turn;
    let is_interactive = engine_target.is_interactive;
    let primitive_identity = primitive_capability_identity(
        &model_primitive_name,
        engine_target,
        ctx.primitive_surface.catalog_revision.0,
        ctx.trace_id,
        ctx.parent_invocation_id,
    );
    let effective_args = Value::Object(capability_invocation.arguments.clone());

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
        crate::shared::model_capabilities::error_result("Operation cancelled")
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
            ctx.trace_id,
            ctx.parent_invocation_id,
            effective_args,
        )
        .await
    } else {
        return CapabilityInvocationExecutionResult {
            invocation_id,
            result: crate::shared::model_capabilities::error_result(format!(
                "Engine host is required to execute capability primitive '{model_primitive_name}'"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            stops_turn,
            is_interactive,
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
        invocation_id,
        result: capability_result,
        duration_ms,
        stops_turn: stops_turn || result_stops_turn,
        is_interactive,
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
    target: &EngineCapabilityTarget,
    model_primitive_name: &str,
    invocation_id: &str,
    session_id: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    turn: i64,
    run_id: Option<&str>,
    inherited_trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    effective_args: Value,
) -> crate::shared::model_capabilities::CapabilityResult {
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
        Err(error) => return crate::shared::model_capabilities::error_result(error.to_string()),
    };
    let grant_id = match AuthorityGrantId::new("agent-capability-runtime") {
        Ok(id) => id,
        Err(error) => return crate::shared::model_capabilities::error_result(error.to_string()),
    };
    let trace_id = inherited_trace_id
        .cloned()
        .unwrap_or_else(TraceId::generate);
    let mut causal_context = with_agent_working_directory_metadata(
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id),
        working_directory,
    )
    .with_scope("capability.search")
    .with_scope("capability.inspect")
    .with_scope("capability.execute")
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(idempotency_key);
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
    let invocation = Invocation::new_sync(function_id.clone(), effective_args, causal_context)
        .expecting_revision(target.function.revision);
    let result = engine_host.invoke(invocation).await;

    if let Some(error) = result.error {
        return crate::shared::model_capabilities::error_result(format!(
            "Engine capability invocation failed for {function_id}: {error}"
        ));
    }
    let Some(value) = result.value else {
        return crate::shared::model_capabilities::error_result(format!(
            "Engine capability invocation returned no result for {function_id}"
        ));
    };
    serde_json::from_value(value).unwrap_or_else(|error| {
        crate::shared::model_capabilities::error_result(format!(
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
