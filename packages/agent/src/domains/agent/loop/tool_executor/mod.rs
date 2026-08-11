//! Direct model-tool executor for the worker-first surface.
//!
//! Accepted local agent calls enter the engine directly with Agent identity.
//! The engine records actor, session, trace, parent, and deterministic
//! idempotency metadata. Direct kernel functions and active workers own their
//! request/response schemas and reliability contracts at registration.
//! Top-level calls bind idempotency to their provider invocation. Worker-owned
//! calls additionally carry a deterministic per-tool occurrence. The worker
//! kernel uses that durable parent call slot to replay already admitted child
//! work when provider call IDs or valid arguments change after reconstruction.
//!
//! Durable model-tool lifecycle ownership stays in the turn runner. When a
//! session event persister is available, the executor only returns the
//! primitive result; the turn runner persists and broadcasts row-backed
//! `tool.invocation.started` / `completed` events so live clients and
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
use crate::domains::agent::r#loop::surface::{PrimitiveExecutionTarget, ResolvedPrimitiveSurface};
use crate::domains::agent::r#loop::types::ToolInvocationExecutionResult;
use crate::engine::{
    ActorId, ActorKind, CausalContext, EngineHostHandle, FunctionVisibility, Invocation,
    InvocationId, TraceId,
};
use crate::shared::foundation::redaction::{redact_sensitive_content, redact_sensitive_json};
use crate::shared::protocol::content::ToolResultContent;
use crate::shared::protocol::events::{BaseEvent, ToolEventIdentity, TronEvent};
use crate::shared::protocol::messages::ToolInvocationDraft;
use crate::shared::protocol::model_tools::{ToolResult, ToolResultBody, failure_result};
use crate::shared::server::error_mapping::engine_error_to_failure;
use crate::shared::server::failure::{
    ENGINE_POLICY_VIOLATION, FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_CANCELLED,
    TOOL_ENGINE_RESULT_MISSING, TOOL_PRIMITIVE_NOT_FOUND,
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
    tool_name: &str,
    workspace_id: Option<&str>,
    origin_worker_invocation_id: Option<&str>,
    arguments: &Value,
) -> String {
    let material = origin_worker_invocation_id.map_or_else(
        || {
            json!({
                "runId": run_id,
                "sessionId": session_id,
                "turn": turn,
                "providerInvocationId": invocation_id,
                "toolName": tool_name,
                "workspaceId": workspace_id,
                "arguments": arguments,
            })
        },
        |parent_worker_invocation_id| {
            json!({
                "parentWorkerInvocationId":parent_worker_invocation_id,
                "turn":turn,
                "toolName":tool_name,
                "workspaceId":workspace_id,
                "arguments":arguments,
            })
        },
    );
    let material = serde_json::to_vec(&material).unwrap_or_default();
    format!("model-tool:{}", hex::encode(Sha256::digest(material)))
}

fn primitive_tool_identity(
    engine_target: &crate::domains::agent::r#loop::surface::PrimitiveExecutionTarget,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> ToolEventIdentity {
    ToolEventIdentity {
        trace_id: trace_id.map(|id| id.as_str().to_owned()),
        root_invocation_id: parent_invocation_id.map(|id| id.as_str().to_owned()),
        presentation_hints: crate::domains::agent::r#loop::surface::presentation_hints_for_target(
            engine_target,
        ),
        ..ToolEventIdentity::default()
    }
}

fn tool_identity_from_result(
    _tool_name: &str,
    base_identity: &ToolEventIdentity,
    result: &ToolResult,
) -> ToolEventIdentity {
    let Some(details) = result.details.as_ref() else {
        return base_identity.clone();
    };
    ToolEventIdentity {
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

fn redacted_tool_result(result: &ToolResult) -> ToolResult {
    let content = match &result.content {
        ToolResultBody::Text(text) => ToolResultBody::Text(redact_sensitive_content(text)),
        ToolResultBody::Blocks(blocks) => ToolResultBody::Blocks(
            blocks
                .iter()
                .map(|block| match block {
                    ToolResultContent::Text { text } => {
                        ToolResultContent::text(redact_sensitive_content(text))
                    }
                    ToolResultContent::Image { data, mime_type } => {
                        ToolResultContent::image(data.clone(), mime_type.clone())
                    }
                })
                .collect(),
        ),
    };
    ToolResult {
        content,
        details: result.details.as_ref().map(redact_sensitive_json),
        is_error: result.is_error,
    }
}

fn tool_failure_details(
    failure: &mut FailureEnvelope,
    tool_name: &str,
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
    let _ = details.insert("toolName".to_owned(), Value::String(tool_name.to_owned()));
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

fn tool_failure_result(
    mut failure: FailureEnvelope,
    tool_name: &str,
    provider_invocation_id: &str,
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    extra: Option<Value>,
) -> ToolResult {
    tool_failure_details(
        &mut failure,
        tool_name,
        provider_invocation_id,
        session_id,
        trace_id,
        parent_invocation_id,
        extra,
    );
    failure_result(&failure)
}

pub struct ToolExecutionContext<'a> {
    pub primitive_surface: &'a ResolvedPrimitiveSurface,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub workspace_id: Option<&'a str>,
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Whether the executor should emit transient lifecycle events itself.
    ///
    /// Turn-runner callers with a session event persister set this to `false`
    /// because durable model-tool lifecycle events are broadcast from persisted
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
    /// Consecutive automatic coordination wakes inherited by this provider
    /// turn. Agent coordination calls advance it; ordinary tool execution
    /// preserves it.
    pub autonomous_wake_hop: u32,
    /// Worker that owns an agent-runner child session. Tool calls retain that
    /// worker actor identity so semantic hooks can avoid self-recursion.
    pub origin_worker_id: Option<&'a str>,
    /// Durable parent worker invocation for child-run admission and run-tree
    /// reconstruction.
    pub origin_worker_invocation_id: Option<&'a str>,
    /// Stable reusable-agent execution identities, when this run is nested.
    pub agent_id: Option<&'a str>,
    pub agent_assignment_id: Option<&'a str>,
    pub agent_execution_id: Option<&'a str>,
    /// Exact immutable function-id grant and limits for the assignment.
    pub delegated_function_grant: Option<&'a [String]>,
    pub agent_limits: Option<&'a Value>,
    /// Immutable canonical workspace-relative assignment write prefixes.
    pub agent_write_scopes: Option<&'a [String]>,
    /// Zero-based occurrence of this tool inside the owning worker run.
    pub origin_worker_tool_ordinal: Option<u32>,
}

#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(tool_name = tool_invocation.name, session_id))]
pub async fn execute_tool(
    tool_invocation: &ToolInvocationDraft,
    session_id: &str,
    working_directory: &str,
    ctx: &ToolExecutionContext<'_>,
) -> ToolInvocationExecutionResult {
    let start = Instant::now();
    let invocation_id = tool_invocation.id.clone();
    let tool_name = tool_invocation.name.clone();

    let Some(engine_target) = ctx.primitive_surface.targets_by_name.get(&tool_name) else {
        error!(tool_name, "model tool not found");
        let failure = FailureEnvelope::new(
            TOOL_PRIMITIVE_NOT_FOUND,
            FailureCategory::NotFound,
            format!("Model tool not found: {tool_name}"),
            false,
            true,
            FailureOrigin::Tool,
        );
        return ToolInvocationExecutionResult {
            result: tool_failure_result(
                failure,
                &tool_name,
                &invocation_id,
                session_id,
                ctx.trace_id,
                ctx.parent_invocation_id,
                None,
            ),
            duration_ms: duration_ceil_ms(start.elapsed()),
        };
    };

    let effective_args = Value::Object(tool_invocation.arguments.clone());
    let primitive_identity =
        primitive_tool_identity(engine_target, ctx.trace_id, ctx.parent_invocation_id);

    if ctx.emit_lifecycle_events {
        let redacted_arguments = redact_sensitive_json(&effective_args).as_object().cloned();
        let started = TronEvent::ToolInvocationStarted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            tool_name: tool_name.clone(),
            arguments: redacted_arguments,
            tool_identity: primitive_identity.clone(),
        };
        emit(ctx, started);
        debug!(
            tool_name,
            invocation_id, session_id, "model tool invocation started"
        );
    }

    let per_invocation_cancel =
        ctx.invocation_abort_registry
            .register(session_id, &invocation_id, ctx.cancel);
    let _abort_guard =
        InvocationAbortGuard::new(ctx.invocation_abort_registry, session_id, &invocation_id);

    let tool_result = if per_invocation_cancel.is_cancelled() {
        let failure = FailureEnvelope::new(
            RUNTIME_CANCELLED,
            FailureCategory::Cancelled,
            "Operation cancelled",
            false,
            true,
            FailureOrigin::Tool,
        );
        tool_failure_result(
            failure,
            &tool_name,
            &invocation_id,
            session_id,
            ctx.trace_id,
            ctx.parent_invocation_id,
            None,
        )
    } else {
        execute_tool_via_engine(
            ctx.engine_host,
            engine_target,
            &tool_name,
            &invocation_id,
            session_id,
            working_directory,
            ctx.workspace_id,
            ctx.turn,
            ctx.run_id,
            ctx.trace_id,
            ctx.parent_invocation_id,
            ctx.worker_causal_depth,
            ctx.autonomous_wake_hop,
            ctx.origin_worker_id,
            ctx.origin_worker_invocation_id,
            ctx.agent_id,
            ctx.agent_assignment_id,
            ctx.agent_execution_id,
            ctx.delegated_function_grant,
            ctx.agent_limits,
            ctx.agent_write_scopes,
            ctx.origin_worker_tool_ordinal,
            effective_args,
            &per_invocation_cancel,
        )
        .await
    };

    let duration_ms = duration_ceil_ms(start.elapsed());
    let resolved_identity =
        tool_identity_from_result(&tool_name, &primitive_identity, &tool_result);

    metrics::counter!("model_tool_invocations_total", "tool" => tool_name.clone()).increment(1);
    metrics::histogram!("model_tool_invocation_duration_seconds", "tool" => tool_name.clone())
        .record(start.elapsed().as_secs_f64());

    if ctx.emit_lifecycle_events {
        let event_result = redacted_tool_result(&tool_result);
        let completed = TronEvent::ToolInvocationCompleted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            tool_name: tool_name.clone(),
            duration: duration_ms,
            is_error: tool_result.is_error,
            result: Some(event_result),
            tool_identity: resolved_identity,
        };
        emit(ctx, completed);
        debug!(tool = %tool_name, duration_ms, "model tool invocation completed");
    }

    ToolInvocationExecutionResult {
        result: tool_result,
        duration_ms,
    }
}

fn emit(ctx: &ToolExecutionContext<'_>, event: TronEvent) {
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
async fn execute_tool_via_engine(
    engine_host: &EngineHostHandle,
    target: &PrimitiveExecutionTarget,
    tool_name: &str,
    invocation_id: &str,
    session_id: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    turn: i64,
    run_id: Option<&str>,
    inherited_trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    worker_causal_depth: u32,
    autonomous_wake_hop: u32,
    origin_worker_id: Option<&str>,
    origin_worker_invocation_id: Option<&str>,
    agent_id: Option<&str>,
    agent_assignment_id: Option<&str>,
    agent_execution_id: Option<&str>,
    delegated_function_grant: Option<&[String]>,
    agent_limits: Option<&Value>,
    agent_write_scopes: Option<&[String]>,
    origin_worker_tool_ordinal: Option<u32>,
    effective_args: Value,
    cancellation: &CancellationToken,
) -> crate::shared::protocol::model_tools::ToolResult {
    let working_directory =
        match crate::shared::foundation::paths::normalize_working_directory(working_directory) {
            Ok(path) => path.display().to_string(),
            Err(error) => {
                let failure = FailureEnvelope::new(
                    ENGINE_POLICY_VIOLATION,
                    FailureCategory::Engine,
                    format!("Tool runtime working directory is not trusted: {error}"),
                    false,
                    false,
                    FailureOrigin::Engine,
                );
                return tool_failure_result(
                    failure,
                    tool_name,
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
        tool_name,
        workspace_id,
        origin_worker_invocation_id,
        &effective_args,
    );
    // INVARIANT: every model-backed execution invokes tools as an Agent. An
    // internal function can enter only through the exact trusted agentTools
    // surface; the function id is carried as an engine-authored grant instead
    // of borrowing System visibility. Ordinary agents cannot manufacture a
    // PrimitiveExecutionTarget or causal grant.
    let trusted_internal_worker_call =
        target.function.visibility == FunctionVisibility::Internal && origin_worker_id.is_some();
    let (actor_identity, actor_kind) = (format!("agent:{session_id}"), ActorKind::Agent);
    let actor_id = match ActorId::new(actor_identity) {
        Ok(id) => id,
        Err(error) => {
            return tool_failure_result(
                engine_error_to_failure(&error),
                tool_name,
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
    let base_context = CausalContext::new(actor_id, actor_kind, trace_id.clone());
    let worker_version = target
        .function
        .model_tool
        .as_ref()
        .and_then(|tool| tool.worker.as_ref())
        .map(|worker| worker.worker_version.clone());
    let mut causal_context = with_agent_working_directory(base_context, &working_directory)
        .with_advertised_function(target.function.revision, worker_version)
        .with_model_tool_invocation_id(invocation_id.to_owned())
        .with_trigger_depth(worker_causal_depth)
        .with_autonomous_wake_hop(autonomous_wake_hop)
        .with_session_id(session_id.to_owned())
        .with_idempotency_key(idempotency_key);
    if let Some(worker_id) = origin_worker_id {
        causal_context = causal_context.with_origin_worker_id(worker_id.to_owned());
    }
    if let Some(grant) = delegated_function_grant {
        causal_context = causal_context.with_delegated_function_grant(grant.to_vec());
    } else if trusted_internal_worker_call {
        causal_context =
            causal_context.with_delegated_function_grant(vec![function_id.as_str().to_owned()]);
    }
    if let Some(agent_id) = agent_id {
        causal_context = match (agent_assignment_id, agent_execution_id) {
            (Some(assignment_id), Some(execution_id)) => causal_context.with_agent_execution(
                agent_id.to_owned(),
                assignment_id.to_owned(),
                execution_id.to_owned(),
            ),
            _ => causal_context.with_agent_identity(agent_id.to_owned()),
        };
    }
    if let Some(limits) = agent_limits {
        causal_context = causal_context.with_agent_limits(limits.clone());
    }
    if let Some(scopes) = agent_write_scopes {
        causal_context = causal_context.with_agent_write_scopes(scopes.to_vec());
    }
    if let Some(workspace_id) = workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.to_owned());
    }
    if let Some(invocation_id) = origin_worker_invocation_id {
        causal_context = causal_context.with_origin_worker_invocation_id(invocation_id.to_owned());
    }
    if let Some(ordinal) = origin_worker_tool_ordinal {
        causal_context = causal_context.with_origin_worker_tool_ordinal(ordinal);
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
            return tool_failure_result(
                engine_error_to_failure(&error),
                tool_name,
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
        return tool_failure_result(
            failure,
            tool_name,
            invocation_id,
            session_id,
            result_trace_id.as_ref(),
            parent_invocation_id,
            Some(json!({ "primitiveTargetId": function_id.to_string() })),
        );
    }
    let Some(value) = result.value else {
        let mut failure = FailureEnvelope::new(
            TOOL_ENGINE_RESULT_MISSING,
            FailureCategory::Tool,
            format!("Engine tool invocation returned no result for {function_id}"),
            false,
            false,
            FailureOrigin::Tool,
        );
        failure.references.trace_id = result_trace_id.as_ref().map(|id| id.as_str().to_owned());
        failure.references.invocation_id = result_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned());
        return tool_failure_result(
            failure,
            tool_name,
            invocation_id,
            session_id,
            result_trace_id.as_ref(),
            parent_invocation_id,
            Some(json!({ "primitiveTargetId": function_id.to_string() })),
        );
    };
    // Worker outputs are typed domain values, never an implicit tool
    // envelope. Always preserve the exact value as details and serialize it for
    // the provider result channel; otherwise a worker whose schema happens to
    // contain `content` or `details` would be misinterpreted by the engine.
    let mut tool_result = ToolResult {
        content: crate::shared::protocol::model_tools::ToolResultBody::Text(
            serde_json::to_string_pretty(&value).unwrap_or_else(|_| value.to_string()),
        ),
        details: Some(value),
        is_error: None,
    };
    attach_engine_outcome(&mut tool_result, replayed_from.as_ref());
    tool_result
}

fn attach_engine_outcome(result: &mut ToolResult, replayed_from: Option<&InvocationId>) {
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
