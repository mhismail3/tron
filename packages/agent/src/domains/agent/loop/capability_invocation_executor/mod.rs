//! Direct model-tool executor for the worker-first surface.
//!
//! Accepted local agent calls enter the engine directly with Agent identity.
//! The engine records actor, session, trace, parent, and deterministic
//! idempotency metadata. Direct kernel functions and active workers own their
//! request/response schemas and reliability contracts at registration.
//!
//! Durable capability lifecycle ownership stays in the turn runner. When a
//! session event persister is available, the executor only returns the
//! primitive result; the turn runner persists and broadcasts row-backed
//! `capability.invocation.started` / `completed` events so live clients and
//! reconstruction share the same sequence source. Transient lifecycle events
//! use redacted argument and result copies; the raw operation result is kept
//! only in memory for the active provider turn.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::{
    InvocationAbortGuard, InvocationAbortRegistry,
};
use crate::domains::agent::r#loop::primitive_surface::{
    PrimitiveExecutionTarget, ResolvedPrimitiveSurface,
};
use crate::domains::agent::r#loop::types::CapabilityInvocationExecutionResult;
use crate::engine::{
    ActorId, ActorKind, CausalContext, EngineHostHandle, Invocation, InvocationId, TraceId,
};
use crate::shared::foundation::redaction::{redact_sensitive_content, redact_sensitive_json};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::events::{BaseEvent, CapabilityEventIdentity, TronEvent};
use crate::shared::protocol::messages::CapabilityInvocationDraft;
use crate::shared::protocol::model_capabilities::{
    CapabilityResult, CapabilityResultBody, failure_result,
};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    CAPABILITY_ENGINE_RESULT_MISSING, CAPABILITY_PRIMITIVE_NOT_FOUND, ENGINE_POLICY_VIOLATION,
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_CANCELLED,
};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, instrument};

use sha2::{Digest, Sha256};

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

fn direct_tool_idempotency_key(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    invocation_id: &str,
    model_primitive_name: &str,
    workspace_id: Option<&str>,
    arguments: &Value,
) -> String {
    let material = serde_json::to_vec(&json!({
        "runId": run_id,
        "sessionId": session_id,
        "turn": turn,
        "providerInvocationId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "workspaceId": workspace_id,
        "arguments": arguments,
    }))
    .unwrap_or_default();
    format!("model-tool:{}", hex::encode(Sha256::digest(material)))
}

fn primitive_capability_identity(
    model_primitive_name: &str,
    _arguments: &Value,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> CapabilityEventIdentity {
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
        trace_id: trace_id.map(|id| id.as_str().to_owned()),
        root_invocation_id: parent_invocation_id.map(|id| id.as_str().to_owned()),
        ..CapabilityEventIdentity::default()
    }
}

fn capability_identity_from_result(
    model_primitive_name: &str,
    base_identity: &CapabilityEventIdentity,
    result: &CapabilityResult,
) -> CapabilityEventIdentity {
    let Some(details) = result.details.as_ref() else {
        return base_identity.clone();
    };
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
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

fn redacted_capability_result(result: &CapabilityResult) -> CapabilityResult {
    let content = match &result.content {
        CapabilityResultBody::Text(text) => {
            CapabilityResultBody::Text(redact_sensitive_content(text))
        }
        CapabilityResultBody::Blocks(blocks) => CapabilityResultBody::Blocks(
            blocks
                .iter()
                .map(|block| match block {
                    CapabilityResultContent::Text { text } => {
                        CapabilityResultContent::text(redact_sensitive_content(text))
                    }
                    CapabilityResultContent::Image { data, mime_type } => {
                        CapabilityResultContent::image(data.clone(), mime_type.clone())
                    }
                })
                .collect(),
        ),
    };
    CapabilityResult {
        content,
        details: result.details.as_ref().map(redact_sensitive_json),
        is_error: result.is_error,
    }
}

fn capability_failure_details(
    failure: &mut FailureEnvelope,
    model_primitive_name: &str,
    provider_invocation_id: &str,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    extra: Option<Value>,
) {
    let mut details = match failure.details.take() {
        Some(Value::Object(object)) => object,
        Some(value) => {
            let mut object = serde_json::Map::new();
            let _ = object.insert("details".to_owned(), value);
            object
        }
        None => serde_json::Map::new(),
    };
    let _ = details.insert(
        "modelPrimitiveName".to_owned(),
        Value::String(model_primitive_name.to_owned()),
    );
    let _ = details.insert(
        "providerInvocationId".to_owned(),
        Value::String(provider_invocation_id.to_owned()),
    );
    if let Some(Value::Object(extra)) = extra {
        details.extend(extra);
    }
    failure.details = Some(Value::Object(details));
    failure.references.session_id = Some(session_id.to_owned());
    failure.references.trace_id = trace_id.map(|id| id.as_str().to_owned());
    failure.references.parent_invocation_id = parent_invocation_id.map(|id| id.as_str().to_owned());
}

fn capability_failure_result(
    mut failure: FailureEnvelope,
    model_primitive_name: &str,
    provider_invocation_id: &str,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    extra: Option<Value>,
) -> CapabilityResult {
    capability_failure_details(
        &mut failure,
        model_primitive_name,
        provider_invocation_id,
        session_id,
        trace_id,
        parent_invocation_id,
        extra,
    );
    failure_result(&failure)
}

pub struct CapabilityInvocationExecutionContext<'a> {
    pub primitive_surface: &'a ResolvedPrimitiveSurface,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub workspace_id: Option<&'a str>,
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Whether the executor should emit transient lifecycle events itself.
    ///
    /// Turn-runner callers with a session event persister set this to `false`
    /// because durable capability lifecycle events are broadcast from persisted
    /// rows using persisted row sequences.
    pub emit_lifecycle_events: bool,
    pub turn: i64,
    pub invocation_abort_registry: &'a InvocationAbortRegistry,
    pub engine_host: &'a EngineHostHandle,
    pub run_id: Option<&'a str>,
    pub trace_id: Option<&'a TraceId>,
    pub parent_invocation_id: Option<&'a InvocationId>,
    /// Depth inherited from a parent worker invocation. Propagating this
    /// engine-owned value prevents an agent-runner hop from restarting a
    /// worker causal trace at zero.
    pub worker_causal_depth: u32,
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
        let failure = FailureEnvelope::new(
            CAPABILITY_PRIMITIVE_NOT_FOUND,
            FailureCategory::NotFound,
            format!("Capability primitive not found: {model_primitive_name}"),
            false,
            true,
            FailureOrigin::Capability,
        );
        return CapabilityInvocationExecutionResult {
            result: capability_failure_result(
                failure,
                &model_primitive_name,
                &invocation_id,
                session_id,
                ctx.trace_id,
                ctx.parent_invocation_id,
                None,
            ),
            duration_ms: duration_ceil_ms(start.elapsed()),
        };
    };

    let effective_args = Value::Object(capability_invocation.arguments.clone());
    let primitive_identity = primitive_capability_identity(
        &model_primitive_name,
        &effective_args,
        ctx.trace_id,
        ctx.parent_invocation_id,
    );

    if ctx.emit_lifecycle_events {
        let redacted_arguments = redact_sensitive_json(&effective_args).as_object().cloned();
        let started = TronEvent::CapabilityInvocationStarted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            model_primitive_name: model_primitive_name.clone(),
            arguments: redacted_arguments,
            capability_identity: primitive_identity.clone(),
        };
        emit(ctx, started);
        debug!(
            model_primitive_name,
            invocation_id, session_id, "capability invocation started"
        );
    }

    let per_invocation_cancel =
        ctx.invocation_abort_registry
            .register(session_id, &invocation_id, ctx.cancel);
    let _abort_guard =
        InvocationAbortGuard::new(ctx.invocation_abort_registry, session_id, &invocation_id);

    let capability_result = if per_invocation_cancel.is_cancelled() {
        let failure = FailureEnvelope::new(
            RUNTIME_CANCELLED,
            FailureCategory::Cancelled,
            "Operation cancelled",
            false,
            true,
            FailureOrigin::Capability,
        );
        capability_failure_result(
            failure,
            &model_primitive_name,
            &invocation_id,
            session_id,
            ctx.trace_id,
            ctx.parent_invocation_id,
            None,
        )
    } else {
        execute_capability_primitive_via_engine(
            ctx.engine_host,
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
            ctx.worker_causal_depth,
            effective_args,
            &per_invocation_cancel,
        )
        .await
    };

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

    if ctx.emit_lifecycle_events {
        let event_result = redacted_capability_result(&capability_result);
        let completed = TronEvent::CapabilityInvocationCompleted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            model_primitive_name: model_primitive_name.clone(),
            duration: duration_ms,
            is_error: capability_result.is_error,
            result: Some(event_result),
            capability_identity: resolved_identity,
        };
        emit(ctx, completed);
        debug!(capability = %model_primitive_name, duration_ms, "capability invocation completed");
    }

    CapabilityInvocationExecutionResult {
        result: capability_result,
        duration_ms,
    }
}

fn emit(ctx: &CapabilityInvocationExecutionContext<'_>, event: TronEvent) {
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(event, counter);
    } else {
        let _ = ctx.emitter.emit(event);
    }
}

fn with_agent_working_directory(context: CausalContext, working_directory: &str) -> CausalContext {
    context.with_working_directory(working_directory)
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
    inherited_trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    worker_causal_depth: u32,
    effective_args: Value,
    cancellation: &CancellationToken,
) -> crate::shared::protocol::model_capabilities::CapabilityResult {
    let working_directory =
        match crate::shared::foundation::paths::normalize_working_directory(working_directory) {
            Ok(path) => path.display().to_string(),
            Err(error) => {
                let failure = FailureEnvelope::new(
                    ENGINE_POLICY_VIOLATION,
                    FailureCategory::Engine,
                    format!("Capability runtime working directory is not trusted: {error}"),
                    false,
                    false,
                    FailureOrigin::Engine,
                );
                return capability_failure_result(
                    failure,
                    model_primitive_name,
                    invocation_id,
                    session_id,
                    inherited_trace_id,
                    parent_invocation_id,
                    None,
                );
            }
        };
    let idempotency_key = direct_tool_idempotency_key(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        workspace_id,
        &effective_args,
    );
    let actor_id = match ActorId::new(format!("agent:{session_id}")) {
        Ok(id) => id,
        Err(error) => {
            return capability_failure_result(
                engine_error_to_failure(&error),
                model_primitive_name,
                invocation_id,
                session_id,
                inherited_trace_id,
                parent_invocation_id,
                None,
            );
        }
    };
    let trace_id = inherited_trace_id
        .cloned()
        .unwrap_or_else(TraceId::generate);
    let function_id = target.function_id.clone();
    let base_context = CausalContext::new(actor_id, ActorKind::Agent, trace_id.clone());
    let worker_version = target
        .function
        .model_tool
        .as_ref()
        .and_then(|tool| tool.worker.as_ref())
        .map(|worker| worker.worker_version.clone());
    let mut causal_context = with_agent_working_directory(base_context, &working_directory)
        .with_advertised_function(target.function.revision, worker_version)
        .with_trigger_depth(worker_causal_depth)
        .with_session_id(session_id.to_owned())
        .with_idempotency_key(idempotency_key);
    if let Some(workspace_id) = workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.to_owned());
    }
    if let Some(parent) = parent_invocation_id {
        causal_context = causal_context.with_parent_invocation(parent.clone());
    }
    let invocation = Invocation::new_sync(function_id.clone(), effective_args, causal_context);
    let result = engine_host
        .invoke_regular_cancellable(invocation, cancellation)
        .await;
    let result = match result {
        Ok(result) => result,
        Err(error) => {
            return capability_failure_result(
                engine_error_to_failure(&error),
                model_primitive_name,
                invocation_id,
                session_id,
                Some(&trace_id),
                parent_invocation_id,
                Some(json!({ "primitiveTargetId": function_id.to_string() })),
            );
        }
    };
    let result_trace_id = Some(result.trace_id.clone());
    let result_invocation_id = Some(result.invocation_id.clone());
    let replayed_from = result.replayed_from.clone();

    if let Some(error) = result.error {
        let mut failure = engine_error_to_failure(&error);
        failure.references.trace_id = result_trace_id.as_ref().map(|id| id.as_str().to_owned());
        failure.references.invocation_id = result_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned());
        return capability_failure_result(
            failure,
            model_primitive_name,
            invocation_id,
            session_id,
            result_trace_id.as_ref(),
            parent_invocation_id,
            Some(json!({ "primitiveTargetId": function_id.to_string() })),
        );
    }
    let Some(value) = result.value else {
        let mut failure = FailureEnvelope::new(
            CAPABILITY_ENGINE_RESULT_MISSING,
            FailureCategory::Capability,
            format!("Engine capability invocation returned no result for {function_id}"),
            false,
            false,
            FailureOrigin::Capability,
        );
        failure.references.trace_id = result_trace_id.as_ref().map(|id| id.as_str().to_owned());
        failure.references.invocation_id = result_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned());
        return capability_failure_result(
            failure,
            model_primitive_name,
            invocation_id,
            session_id,
            result_trace_id.as_ref(),
            parent_invocation_id,
            Some(json!({ "primitiveTargetId": function_id.to_string() })),
        );
    };
    // Worker outputs are typed domain values, never an implicit capability
    // envelope. Always preserve the exact value as details and serialize it for
    // the provider result channel; otherwise a worker whose schema happens to
    // contain `content` or `details` would be misinterpreted by the engine.
    let mut capability_result = CapabilityResult {
        content: crate::shared::protocol::model_capabilities::CapabilityResultBody::Text(
            serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string()),
        ),
        details: Some(value),
        is_error: None,
    };
    attach_engine_outcome(&mut capability_result, replayed_from.as_ref());
    capability_result
}

fn attach_engine_outcome(result: &mut CapabilityResult, replayed_from: Option<&InvocationId>) {
    let Some(Value::Object(details)) = result.details.as_mut() else {
        return;
    };
    details.insert(
        "engineOutcome".to_owned(),
        json!({
            "replayed": replayed_from.is_some(),
            "replaySourceInvocationRef": replayed_from.map(InvocationId::as_str)
        }),
    );
}

#[cfg(test)]
mod tests;
