//! Tool executor — guardrails → pre-hooks → execute → post-hooks pipeline.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::domains::agent::runner::context::local_policy;
use crate::domains::agent::runner::guardrails::{EvaluationContext, GuardrailEngine};
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::hooks::types::{HookAction, HookContext};
use crate::domains::capability::registry::CapabilitySearchPolicy;
use crate::domains::capability_support::implementations::capability_surface::{
    CapabilitySurfacePolicy, EngineToolTarget, ResolvedToolSurface,
};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation,
    InvocationId, TraceId,
};
use crate::shared::events::{
    BaseEvent, CapabilityEventIdentity, HookResult as EventHookResult, TronEvent,
};
use crate::shared::messages::Provider;
use crate::shared::messages::ToolCall;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::orchestrator::tool_abort_registry::{
    ToolAbortGuard, ToolAbortRegistry,
};
use crate::domains::agent::runner::types::ToolExecutionResult;

/// Convert a `Duration` to milliseconds, rounding up (ceiling).
///
/// `Duration::as_millis()` truncates sub-millisecond values to 0, which makes
/// fast tools (file glob, `SQLite` lookup) report "0ms". This function ensures
/// at least 1ms is reported for any non-zero duration.
fn duration_ceil_ms(d: Duration) -> u64 {
    let micros = d.as_micros();
    if micros == 0 {
        return 0;
    }
    // Ceiling division: (micros + 999) / 1000, minimum 1
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

fn primitive_capability_identity(
    model_tool_name: &str,
    target: &EngineToolTarget,
    catalog_revision: u64,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> CapabilityEventIdentity {
    let function = &target.function;
    let function_id = function.id.as_str().to_owned();
    CapabilityEventIdentity {
        model_tool_name: Some(model_tool_name.to_owned()),
        contract_id: string_metadata(function, "contractId")
            .or_else(|| string_metadata(function, "capabilityContractId"))
            .or_else(|| Some(function_id.clone())),
        implementation_id: string_metadata(function, "implementationId")
            .or_else(|| string_metadata(function, "capabilityImplementationId"))
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
    }
}

fn capability_identity_from_result(
    model_tool_name: &str,
    base_identity: &CapabilityEventIdentity,
    result: &crate::shared::tools::CapabilityResult,
) -> CapabilityEventIdentity {
    let Some(details) = result.details.as_ref() else {
        return base_identity.clone();
    };
    let binding = details.get("bindingDecision");
    CapabilityEventIdentity {
        model_tool_name: Some(model_tool_name.to_owned()),
        contract_id: binding
            .and_then(|value| value.get("contractId"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.contract_id.clone()),
        implementation_id: details
            .get("selectedImplementation")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| {
                binding
                    .and_then(|value| value.get("selectedImplementation"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .or_else(|| base_identity.implementation_id.clone()),
        function_id: details
            .get("functionId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| {
                binding
                    .and_then(|value| value.get("selectedFunctionId"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .or_else(|| base_identity.function_id.clone()),
        plugin_id: details
            .get("pluginVersions")
            .and_then(Value::as_array)
            .and_then(|plugins| plugins.first())
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.plugin_id.clone()),
        worker_id: base_identity.worker_id.clone(),
        schema_digest: details
            .get("schemaDigest")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| {
                binding
                    .and_then(|value| value.get("schemaDigest"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
            })
            .or_else(|| base_identity.schema_digest.clone()),
        catalog_revision: details
            .get("catalogRevision")
            .and_then(Value::as_u64)
            .or_else(|| {
                binding
                    .and_then(|value| value.get("catalogRevision"))
                    .and_then(Value::as_u64)
            })
            .or(base_identity.catalog_revision),
        trust_tier: base_identity.trust_tier.clone(),
        risk_level: base_identity.risk_level.clone(),
        effect_class: base_identity.effect_class.clone(),
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
        binding_decision_id: binding
            .and_then(|value| value.get("decisionId"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| base_identity.binding_decision_id.clone()),
    }
}

fn execution_request_target(args: &Value) -> (Option<String>, Option<String>, Option<String>) {
    let direct = args
        .get("mode")
        .and_then(Value::as_str)
        .is_none_or(|mode| mode == "invoke");
    if !direct {
        return (None, None, None);
    }
    let payload = args.get("payload").unwrap_or(args);
    let contract_id = payload
        .get("contractId")
        .or_else(|| payload.get("contract_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let implementation_id = payload
        .get("implementationId")
        .or_else(|| payload.get("implementation_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let function_id = payload
        .get("functionId")
        .or_else(|| payload.get("function_id"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    (contract_id, implementation_id, function_id)
}

/// Shared dependencies for capability invocation (extracted to reduce parameter count).
pub struct ToolExecutionContext<'a> {
    /// Live engine-catalog tool surface resolved for this turn.
    pub tool_surface: &'a ResolvedToolSurface,
    /// Profile/session capability policy that gates direct execute targets.
    pub capability_policy: &'a CapabilitySurfacePolicy,
    /// Optional guardrail engine for pre-execution validation.
    pub guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Optional hook engine for pre/post tool-use hooks.
    pub hooks: &'a Option<Arc<HookEngine>>,
    /// Event emitter for tool lifecycle events.
    pub emitter: &'a Arc<EventEmitter>,
    /// Cancellation token for cooperative cancellation.
    pub cancel: &'a CancellationToken,
    /// Current subagent nesting depth.
    pub subagent_depth: u32,
    /// Maximum allowed subagent nesting depth.
    pub subagent_max_depth: u32,
    /// Workspace identifier for scoped memory recall.
    pub workspace_id: Option<&'a str>,
    /// Optional process manager for background process execution.
    pub process_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    /// Optional unified job manager for process + subagent lifecycle.
    pub job_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>,
    >,
    /// Optional output buffer registry for on-demand process output streaming.
    pub output_buffer_registry: Option<
        &'a Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    /// Optional per-session sequence counter for monotonic event ordering.
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Provider type of the active model. Used to enforce the local-model
    /// tool allow-list at the execution boundary (see `local_policy`).
    pub provider_type: Provider,
    /// Optional execution spec selected by the current session profile.
    pub execution_spec: Option<&'a crate::shared::profile::AgentExecutionSpec>,
    /// Hash of the resolved profile spec that selected this runtime policy.
    pub profile_spec_hash: Option<&'a str>,
    /// Optional persister for durable progress events emitted by domain-owned
    /// capabilities that report incremental progress.
    pub event_persister: Option<
        &'a Arc<crate::domains::agent::runner::orchestrator::event_persister::EventPersister>,
    >,
    /// Turn number this capability invocation belongs to. Copied into each progress event
    /// so iOS can attribute progress after disconnect/reconnect.
    pub turn: i64,
    /// Optional per-call abort registry. When `Some`, each model capability invocation registers
    /// a child `CancellationToken` so `agent.abortTool` can cancel one capability
    /// primitive without aborting the whole turn. When `None`, the turn-level
    /// `cancel` token is passed through unchanged.
    pub tool_abort_registry: Option<&'a Arc<ToolAbortRegistry>>,
    /// Optional engine host for routing model-facing capability primitives.
    pub engine_host: Option<&'a EngineHostHandle>,
    /// Stable run id used for model capability-invocation idempotency.
    pub run_id: Option<&'a str>,
    /// Trace inherited from the owning agent run-turn invocation.
    pub trace_id: Option<&'a TraceId>,
    /// Parent invocation inherited from the owning agent run-turn invocation.
    pub parent_invocation_id: Option<&'a InvocationId>,
}

/// Execute a single capability invocation through the full pipeline.
///
/// Pipeline: guardrails → pre-hooks → execute → post-hooks → result
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(tool_name = tool_call.name, session_id))]
pub async fn execute_tool(
    tool_call: &ToolCall,
    session_id: &str,
    working_directory: &str,
    ctx: &ToolExecutionContext<'_>,
) -> ToolExecutionResult {
    let start = Instant::now();
    let tool_call_id = tool_call.id.clone();
    let tool_name = tool_call.name.clone();

    // 1. Resolve the model capability id through the live engine catalog captured
    // at the provider request boundary.
    let engine_target = ctx.tool_surface.targets_by_name.get(&tool_name);
    if engine_target.is_none() {
        error!(tool_name, "tool not found");
        return ToolExecutionResult {
            tool_call_id,
            result: crate::shared::tools::error_result(format!("Tool not found: {tool_name}")),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn: false,
            is_interactive: false,
        };
    }

    let stops_turn = engine_target.is_some_and(|target| target.stops_turn);
    let is_interactive = engine_target.is_some_and(|target| target.is_interactive);
    let primitive_identity = primitive_capability_identity(
        &tool_name,
        engine_target.expect("checked above"),
        ctx.tool_surface.catalog_revision.0,
        ctx.trace_id,
        ctx.parent_invocation_id,
    );

    // 1a. Provider-scoped allow-list. Local models only see a subset of tool
    // schemas; if the model hallucinates a call to a hidden tool, refuse
    // execution here so the gate is enforced at the execution boundary (not
    // only at schema-rendering time).
    let spec = ctx
        .execution_spec
        .expect("ToolExecutionContext.execution_spec must come from the session execution plan");
    let context_policy =
        local_policy::ContextPolicy::from_entrypoint_with_spec(ctx.provider_type, spec, "main");
    let allowed_capabilities = context_policy.capability_filter();
    if context_policy.is_local()
        && let Some(allowed) = allowed_capabilities.as_ref()
        && !allowed.iter().any(|allowed| allowed == &tool_name)
    {
        warn!(tool_name, "tool not available for local model");
        return ToolExecutionResult {
            tool_call_id,
            result: crate::shared::tools::error_result(format!(
                "Tool '{tool_name}' is not available for local models. Use one of: {}.",
                allowed.join(", ")
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn: false,
            is_interactive: false,
        };
    }

    let mut effective_args = Value::Object(tool_call.arguments.clone());

    // 2. Evaluate guardrails (synchronous)
    if let Some(guardrail_engine) = ctx.guardrails {
        let guardrail_tool_name = guardrail_capability_id(&tool_name, &effective_args);
        let guardrail_arguments = guardrail_capability_arguments(&tool_name, &effective_args);
        let eval_ctx = EvaluationContext {
            tool_name: guardrail_tool_name,
            tool_arguments: guardrail_arguments,
            session_id: Some(session_id.to_owned()),
            tool_call_id: Some(tool_call_id.clone()),
        };
        {
            let mut engine = guardrail_engine.lock();
            let eval = engine.evaluate(&eval_ctx);
            if eval.blocked {
                warn!(tool_name, "blocked by guardrail");
                let reason = eval
                    .block_reason
                    .unwrap_or_else(|| "Blocked by guardrail".into());
                return ToolExecutionResult {
                    tool_call_id,
                    result: crate::shared::tools::error_result(reason),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: false,
                    blocked_by_guardrail: true,
                    stops_turn,
                    is_interactive,
                };
            }
        }
    }

    // 3. Execute PreToolUse hooks (blocking, sequential)
    if let Some(hook_engine) = ctx.hooks {
        let hook_ctx = HookContext::PreToolUse {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            tool_name: tool_name.clone(),
            tool_arguments: effective_args.clone(),
            tool_call_id: tool_call_id.clone(),
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookTriggered {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PreToolUse".into(),
                    tool_name: Some(tool_name.clone()),
                    tool_call_id: Some(tool_call_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PreToolUse".into(),
                tool_name: Some(tool_name.clone()),
                tool_call_id: Some(tool_call_id.clone()),
            });
        }
        let result = hook_engine.execute(&hook_ctx).await;
        let event_result = match result.action {
            HookAction::Block => EventHookResult::Block,
            HookAction::Modify => EventHookResult::Modify,
            // AddContext is a no-op on PreToolUse (tools don't accept
            // context injection). Map to Continue so the event wire
            // format is unchanged.
            HookAction::Continue | HookAction::AddContext => EventHookResult::Continue,
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookCompleted {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PreToolUse".into(),
                    result: event_result,
                    duration: None,
                    reason: result.reason.clone(),
                    tool_name: Some(tool_name.clone()),
                    tool_call_id: Some(tool_call_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookCompleted {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PreToolUse".into(),
                result: event_result,
                duration: None,
                reason: result.reason.clone(),
                tool_name: Some(tool_name.clone()),
                tool_call_id: Some(tool_call_id.clone()),
            });
        }
        match result.action {
            HookAction::Block => {
                warn!(tool_name, "blocked by PreToolUse hook");
                let reason = result
                    .reason
                    .unwrap_or_else(|| "Blocked by PreToolUse hook".into());
                return ToolExecutionResult {
                    tool_call_id,
                    result: crate::shared::tools::error_result(reason),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: true,
                    blocked_by_guardrail: false,
                    stops_turn,
                    is_interactive,
                };
            }
            HookAction::Modify => {
                if let Some(mods) = result.modifications {
                    effective_args = mods;
                }
            }
            // AddContext has no meaning on a PreToolUse hook (tools
            // don't carry a prompt to inject into). Handle it cleanly
            // rather than producing a behavioral surprise.
            HookAction::Continue | HookAction::AddContext => {}
        }
    }

    // 4. Emit CapabilityInvocationStarted
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(
            TronEvent::CapabilityInvocationStarted {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                tool_call_id: tool_call_id.clone(),
                tool_name: tool_name.clone(),
                arguments: effective_args.as_object().cloned(),
                capability_identity: primitive_identity.clone(),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::CapabilityInvocationStarted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            arguments: effective_args.as_object().cloned(),
            capability_identity: primitive_identity.clone(),
        });
    }
    if tool_name == "execute" {
        let (requested_contract_id, requested_implementation_id, requested_function_id) =
            execution_request_target(&effective_args);
        if requested_implementation_id.is_none() && requested_function_id.is_none() {
            let event = TronEvent::CapabilityResolution {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                tool_call_id: tool_call_id.clone(),
                model_tool_name: tool_name.clone(),
                requested_contract_id,
                requested_implementation_id,
                requested_function_id,
                capability_identity: primitive_identity.clone(),
            };
            if let Some(counter) = ctx.sequence_counter {
                let _ = ctx.emitter.emit_sequenced(event, counter);
            } else {
                let _ = ctx.emitter.emit(event);
            }
        }
    }
    debug!(
        tool_name,
        tool_call_id, session_id, "capability invocation started"
    );

    // 5. Execute the capability primitive.
    //
    // When a `tool_abort_registry` is present, derive a child `CancellationToken`
    // scoped to this single call. `agent.abortTool` cancels the child; parent
    // (turn-level) cancellation still propagates to every child automatically.
    // The RAII guard ensures the registry entry is removed on every exit path
    // (normal return, error, panic).
    let (per_tool_cancel, _abort_guard) = match ctx.tool_abort_registry {
        Some(registry) => {
            let child = registry.register(session_id, &tool_call_id, ctx.cancel);
            let guard = ToolAbortGuard::new(Arc::clone(registry), session_id, &tool_call_id);
            (child, Some(guard))
        }
        None => (ctx.cancel.clone(), None),
    };

    let tool_result = if per_tool_cancel.is_cancelled() {
        crate::shared::tools::error_result("Operation cancelled")
    } else if let (Some(engine_host), Some(target)) = (ctx.engine_host, engine_target) {
        let execution_policy_scopes = ctx.capability_policy.execution_policy_scopes();
        match primitive_runtime_metadata(ctx, &context_policy) {
            Ok(runtime_metadata) => {
                execute_capability_primitive_via_engine(
                    engine_host,
                    target,
                    &tool_name,
                    &tool_call_id,
                    session_id,
                    working_directory,
                    ctx.workspace_id,
                    ctx.turn,
                    ctx.run_id,
                    ctx.trace_id,
                    ctx.parent_invocation_id,
                    &execution_policy_scopes,
                    &runtime_metadata,
                    effective_args,
                )
                .await
            }
            Err(error) => crate::shared::tools::error_result(error),
        }
    } else {
        return ToolExecutionResult {
            tool_call_id,
            result: crate::shared::tools::error_result(format!(
                "Engine host is required to execute tool '{tool_name}'"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn,
            is_interactive,
        };
    };

    let duration_ms = duration_ceil_ms(start.elapsed());
    let resolved_identity =
        capability_identity_from_result(&tool_name, &primitive_identity, &tool_result);

    // Record capability invocation metrics
    counter!("capability_invocations_total", "capability" => tool_name.clone()).increment(1);
    histogram!("capability_invocation_duration_seconds", "capability" => tool_name.clone())
        .record(start.elapsed().as_secs_f64());

    // 6. Emit CapabilityInvocationCompleted
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(
            TronEvent::CapabilityInvocationCompleted {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                tool_call_id: tool_call_id.clone(),
                tool_name: tool_name.clone(),
                duration: duration_ms,
                is_error: tool_result.is_error,
                result: Some(tool_result.clone()),
                capability_identity: resolved_identity.clone(),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::CapabilityInvocationCompleted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            duration: duration_ms,
            is_error: tool_result.is_error,
            result: Some(tool_result.clone()),
            capability_identity: resolved_identity,
        });
    }
    debug!(tool = %tool_name, duration_ms, "tool executed");

    // 7. Execute PostToolUse hooks (background, fire-and-forget)
    if let Some(hook_engine) = ctx.hooks {
        let hook_ctx = HookContext::PostToolUse {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            tool_name: tool_name.clone(),
            tool_call_id: tool_call_id.clone(),
            result: serde_json::to_value(&tool_result).unwrap_or_default(),
            duration_ms,
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookTriggered {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PostToolUse".into(),
                    tool_name: Some(tool_name.clone()),
                    tool_call_id: Some(tool_call_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PostToolUse".into(),
                tool_name: Some(tool_name.clone()),
                tool_call_id: Some(tool_call_id.clone()),
            });
        }
        // PostToolUse hooks run fire-and-forget with a 30s timeout to prevent leaks.
        let engine = hook_engine.clone();
        let emitter_bg = ctx.emitter.clone();
        let sid = session_id.to_owned();
        let tn = tool_name.clone();
        let tcid = tool_call_id.clone();
        let hook_trace_id = ctx.trace_id.map(|id| id.as_str().to_owned());
        let hook_parent_invocation_id = ctx.parent_invocation_id.map(|id| id.as_str().to_owned());
        let _handle = tokio::spawn(async move {
            match tokio::time::timeout(
                std::time::Duration::from_secs(30),
                engine.execute(&hook_ctx),
            )
            .await
            {
                Ok(bg_result) => {
                    let event_result = match bg_result.action {
                        HookAction::Block => EventHookResult::Block,
                        HookAction::Modify => EventHookResult::Modify,
                        // AddContext on PostToolUse is a no-op — a
                        // completed tool has no prompt surface to
                        // inject context into.
                        HookAction::Continue | HookAction::AddContext => EventHookResult::Continue,
                    };
                    let _ = emitter_bg.emit(TronEvent::HookCompleted {
                        base: BaseEvent::now(&sid)
                            .with_trace_context(hook_trace_id, hook_parent_invocation_id),
                        hook_names: vec![],
                        hook_event: "PostToolUse".into(),
                        result: event_result,
                        duration: None,
                        reason: bg_result.reason.clone(),
                        tool_name: Some(tn),
                        tool_call_id: Some(tcid),
                    });
                }
                Err(_) => {
                    warn!(
                        tool_name = %tn,
                        tool_call_id = %tcid,
                        "PostToolUse hook timed out after 30s"
                    );
                }
            }
        });
    }

    ToolExecutionResult {
        tool_call_id,
        result: tool_result,
        duration_ms,
        blocked_by_hook: false,
        blocked_by_guardrail: false,
        stops_turn,
        is_interactive,
    }
}

fn guardrail_capability_id(model_tool_name: &str, args: &Value) -> String {
    if model_tool_name != "execute" {
        return model_tool_name.to_owned();
    }
    [
        "contractId",
        "implementationId",
        "functionId",
        "capabilityId",
    ]
    .iter()
    .find_map(|key| args.get(key).and_then(Value::as_str))
    .unwrap_or(model_tool_name)
    .to_owned()
}

fn guardrail_capability_arguments(model_tool_name: &str, args: &Value) -> Value {
    if model_tool_name == "execute"
        && let Some(payload) = args.get("payload")
    {
        return payload.clone();
    }
    args.clone()
}

fn primitive_runtime_metadata(
    ctx: &ToolExecutionContext<'_>,
    context_policy: &local_policy::ContextPolicy,
) -> Result<Vec<(String, String)>, String> {
    let spec = ctx
        .execution_spec
        .ok_or_else(|| "capability primitive runtime requires an execution spec".to_owned())?;
    let entrypoint = spec
        .entrypoints
        .get("main")
        .ok_or_else(|| "capability primitive runtime requires entrypoints.main".to_owned())?;
    let capability_policy_id = context_policy
        .capability_policy_id()
        .unwrap_or(entrypoint.capability_policy.as_str());
    let capability_policy = spec
        .capability_policy(capability_policy_id)
        .ok_or_else(|| format!("missing capability policy '{capability_policy_id}'"))?;
    let search_policy_id = capability_policy
        .search_policy
        .as_deref()
        .unwrap_or("hybridLocal");
    let search_policy = spec
        .capability_search_policy(search_policy_id)
        .ok_or_else(|| format!("missing capability search policy '{search_policy_id}'"))?;
    let context_primer_policy_id = capability_policy
        .context_primer_policy
        .as_deref()
        .unwrap_or("coreFirstParty");
    let serialized_search_policy =
        serde_json::to_string(&CapabilitySearchPolicy::from_profile(search_policy))
            .map_err(|error| format!("serialize capability search policy: {error}"))?;
    let mut metadata = vec![
        (
            "capability.capabilityPolicyId".to_owned(),
            capability_policy_id.to_owned(),
        ),
        (
            "capability.searchPolicyId".to_owned(),
            search_policy_id.to_owned(),
        ),
        (
            "capability.contextPrimerPolicyId".to_owned(),
            context_primer_policy_id.to_owned(),
        ),
        (
            "capability.searchPolicy".to_owned(),
            serialized_search_policy,
        ),
    ];
    if let Some(hash) = ctx.profile_spec_hash {
        metadata.push(("capability.profileSpecHash".to_owned(), hash.to_owned()));
    }
    Ok(metadata)
}

#[allow(clippy::too_many_arguments)]
async fn execute_capability_primitive_via_engine(
    engine_host: &EngineHostHandle,
    target: &EngineToolTarget,
    tool_name: &str,
    tool_call_id: &str,
    session_id: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    turn: i64,
    run_id: Option<&str>,
    inherited_trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
    execution_policy_scopes: &[String],
    runtime_metadata: &[(String, String)],
    effective_args: Value,
) -> crate::shared::tools::CapabilityResult {
    let material = stable_tool_call_material(
        run_id,
        session_id,
        turn,
        tool_call_id,
        tool_name,
        working_directory,
        workspace_id,
        &effective_args,
    );
    let fingerprint = sha256_hex(material.as_bytes());
    let idempotency_key = format!("model-capability-invocation:v1:{fingerprint}");
    let function_id = target.function_id.clone();
    let actor_id = match ActorId::new(format!("agent:{session_id}")) {
        Ok(id) => id,
        Err(error) => return crate::shared::tools::error_result(error.to_string()),
    };
    let grant_id = match AuthorityGrantId::new("agent-tool-runtime") {
        Ok(id) => id,
        Err(error) => return crate::shared::tools::error_result(error.to_string()),
    };
    let trace_id = inherited_trace_id
        .cloned()
        .unwrap_or_else(TraceId::generate);
    let mut causal_context = CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("capability.search")
        .with_scope("capability.inspect")
        .with_scope("capability.execute")
        .with_session_id(session_id.to_owned())
        .with_idempotency_key(idempotency_key);
    for scope in execution_policy_scopes {
        if !causal_context.has_scope(scope) {
            causal_context = causal_context.with_scope(scope.clone());
        }
    }
    for (key, value) in runtime_metadata {
        causal_context = causal_context.with_runtime_metadata(key.clone(), value.clone());
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
    let payload = effective_args;
    let invocation = Invocation::new_sync(function_id.clone(), payload, causal_context)
        .expecting_revision(target.function.revision);
    let result = engine_host.invoke(invocation).await;

    if let Some(error) = result.error {
        return crate::shared::tools::error_result(format!(
            "Engine tool invocation failed for {function_id}: {error}"
        ));
    }
    let Some(value) = result.value else {
        return crate::shared::tools::error_result(format!(
            "Engine tool invocation returned no result for {function_id}"
        ));
    };
    serde_json::from_value(value).unwrap_or_else(|error| {
        crate::shared::tools::error_result(format!(
            "Engine tool invocation returned invalid capability result for {function_id}: {error}"
        ))
    })
}

#[allow(clippy::too_many_arguments)]
fn stable_tool_call_material(
    run_id: Option<&str>,
    session_id: &str,
    turn: i64,
    tool_call_id: &str,
    tool_name: &str,
    working_directory: &str,
    workspace_id: Option<&str>,
    effective_args: &Value,
) -> String {
    let payload = json!({
        "runId": run_id,
        "sessionId": session_id,
        "turn": turn,
        "toolCallId": tool_call_id,
        "toolName": tool_name,
        "workingDirectory": working_directory,
        "workspaceId": workspace_id,
        "arguments": effective_args,
    });
    serde_json::to_string(&payload).unwrap_or_else(|_| format!(
        "{:?}:{session_id}:{turn}:{tool_call_id}:{tool_name}:{working_directory}:{workspace_id:?}:{effective_args}",
        run_id
    ))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
    use crate::domains::capability_support::implementations::capability_surface::{
        CapabilitySurfacePolicy, EngineToolTarget, ResolvedToolSurface, resolve_provider_tools,
    };
    use crate::domains::capability_support::implementations::traits::ExecutionMode;
    use crate::engine::{
        AuthorityRequirement, EffectClass, FunctionDefinition, FunctionId, RiskLevel,
        VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
    };
    use crate::shared::tools::ToolResultBody;
    use async_trait::async_trait;
    use parking_lot::Mutex;
    use std::collections::{BTreeMap, HashSet};

    fn default_execution_spec() -> crate::shared::profile::AgentExecutionSpec {
        let tempdir = tempfile::tempdir().expect("profile tempdir");
        let home = tempdir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).expect("seed profile home");
        let profile = crate::shared::profile::resolve_profile_at(
            &home,
            crate::shared::profile::NORMAL_PROFILE,
        )
        .expect("normal profile");
        std::mem::forget(tempdir);
        profile.spec
    }

    fn empty_surface() -> ResolvedToolSurface {
        ResolvedToolSurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            tools: Vec::new(),
            targets_by_name: BTreeMap::new(),
            all_tool_names: Vec::new(),
            turn_stopping_tools: HashSet::new(),
        }
    }

    fn surface_with_echo() -> ResolvedToolSurface {
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
        let target = EngineToolTarget {
            model_tool_name: "execute".to_owned(),
            function_id,
            function,
            stops_turn: true,
            is_interactive: false,
            execution_mode: ExecutionMode::Parallel,
        };
        let mut targets_by_name = BTreeMap::new();
        let _ = targets_by_name.insert("execute".to_owned(), target);
        ResolvedToolSurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            tools: Vec::new(),
            targets_by_name,
            all_tool_names: vec!["execute".to_owned()],
            turn_stopping_tools: HashSet::from(["execute".to_owned()]),
        }
    }

    fn tool_exec_ctx<'a>(
        surface: &'a ResolvedToolSurface,
        emitter: &'a Arc<EventEmitter>,
        cancel: &'a CancellationToken,
        execution_spec: &'a crate::shared::profile::AgentExecutionSpec,
    ) -> ToolExecutionContext<'a> {
        ToolExecutionContext {
            tool_surface: surface,
            capability_policy: &DEFAULT_CAPABILITY_POLICY,
            guardrails: &None,
            hooks: &None,
            emitter,
            cancel,
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            sequence_counter: None,
            provider_type: Provider::Anthropic,
            execution_spec: Some(execution_spec),
            profile_spec_hash: Some("test-profile-hash"),
            event_persister: None,
            turn: 1,
            tool_abort_registry: None,
            engine_host: None,
            run_id: Some("run-1"),
            trace_id: None,
            parent_invocation_id: None,
        }
    }

    static DEFAULT_CAPABILITY_POLICY: std::sync::LazyLock<CapabilitySurfacePolicy> =
        std::sync::LazyLock::new(CapabilitySurfacePolicy::default);

    #[tokio::test]
    async fn unknown_model_tool_fails_before_execution() {
        let surface = empty_surface();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let spec = default_execution_spec();
        let ctx = tool_exec_ctx(&surface, &emitter, &cancel, &spec);
        let call = ToolCall::new("tc1", "Missing", Default::default());
        let result = execute_tool(&call, "s1", "/tmp", &ctx).await;
        assert!(result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn catalog_target_requires_engine_host_for_execution() {
        let surface = surface_with_echo();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let spec = default_execution_spec();
        let ctx = tool_exec_ctx(&surface, &emitter, &cancel, &spec);
        let call = ToolCall::new("tc1", "execute", Default::default());
        let result = execute_tool(&call, "s1", "/tmp", &ctx).await;
        assert!(result.result.is_error.unwrap_or(false));
        assert!(result.stops_turn);
    }

    #[tokio::test]
    async fn model_tool_call_invokes_capability_primitive_through_engine() {
        let server = crate::shared::server::test_support::make_test_context();
        let spec = default_execution_spec();
        let context_policy =
            crate::domains::agent::runner::context::local_policy::ContextPolicy::from_provider_with_spec(
                Provider::Anthropic,
                &spec,
            );
        let surface = resolve_provider_tools(
            &server.engine_host,
            "s1",
            None,
            Provider::Anthropic,
            &context_policy,
            &CapabilitySurfacePolicy::default(),
        )
        .await
        .expect("provider tool surface");
        assert_eq!(surface.all_tool_names, vec!["search", "inspect", "execute"]);
        assert!(surface.targets_by_name.contains_key("execute"));

        let tempdir = tempfile::tempdir().expect("tool tempdir");
        let file_path = tempdir.path().join("note.txt");
        std::fs::write(&file_path, "hello from engine").expect("write fixture");

        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let mut ctx = tool_exec_ctx(&surface, &emitter, &cancel, &spec);
        ctx.engine_host = Some(&server.engine_host);

        let mut args = serde_json::Map::new();
        args.insert("mode".to_owned(), Value::String("invoke".to_owned()));
        args.insert(
            "functionId".to_owned(),
            Value::String("filesystem::read_file".to_owned()),
        );
        args.insert(
            "payload".to_owned(),
            json!({"path": file_path.to_string_lossy()}),
        );
        let call = ToolCall::new("tc1", "execute", args);
        let result = execute_tool(
            &call,
            "s1",
            tempdir.path().to_str().expect("utf8 tempdir"),
            &ctx,
        )
        .await;

        assert_eq!(result.result.is_error, None);
        match result.result.content {
            ToolResultBody::Text(text) => assert!(text.contains("hello from engine")),
            ToolResultBody::Blocks(blocks) => {
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
    struct CapturingToolHandler {
        captured: Arc<Mutex<Option<Invocation>>>,
    }

    #[async_trait]
    impl crate::engine::InProcessFunctionHandler for CapturingToolHandler {
        async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
            *self.captured.lock() = Some(invocation);
            Ok(json!({"content": "ok"}))
        }
    }

    #[tokio::test]
    async fn model_tool_call_inherits_agent_trace_parent_and_idempotency() {
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
                Some(Arc::new(CapturingToolHandler {
                    captured: Arc::clone(&captured),
                })),
                false,
            )
            .await
            .expect("register function");

        let mut targets_by_name = BTreeMap::new();
        let _ = targets_by_name.insert(
            "execute".to_owned(),
            EngineToolTarget {
                model_tool_name: "execute".to_owned(),
                function_id,
                function,
                stops_turn: false,
                is_interactive: false,
                execution_mode: ExecutionMode::Parallel,
            },
        );
        let surface = ResolvedToolSurface {
            catalog_revision: crate::engine::CatalogRevision(42),
            tools: Vec::new(),
            targets_by_name,
            all_tool_names: vec!["execute".to_owned()],
            turn_stopping_tools: HashSet::new(),
        };
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let spec = default_execution_spec();
        let mut ctx = tool_exec_ctx(&surface, &emitter, &cancel, &spec);
        let trace_id = TraceId::new("agent-trace").expect("trace id");
        let parent_invocation_id = InvocationId::new("agent-run-turn").expect("invocation id");
        ctx.engine_host = Some(&engine_host);
        ctx.trace_id = Some(&trace_id);
        ctx.parent_invocation_id = Some(&parent_invocation_id);

        let mut args = serde_json::Map::new();
        args.insert("value".to_owned(), Value::String("hello".to_owned()));
        let call = ToolCall::new("capability-invocation-1", "execute", args);
        let result = execute_tool(&call, "session-1", "/tmp/worktree", &ctx).await;

        assert_eq!(result.result.is_error, None);
        let invocation = captured
            .lock()
            .clone()
            .expect("tool invocation should be captured");
        assert_eq!(invocation.causal_context.trace_id, trace_id);
        assert_eq!(
            invocation.causal_context.parent_invocation_id,
            Some(parent_invocation_id)
        );
        let expected_material = stable_tool_call_material(
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

    #[test]
    fn stable_tool_call_material_changes_with_arguments() {
        let a = stable_tool_call_material(
            Some("run"),
            "s1",
            1,
            "tc1",
            "Echo",
            "/tmp",
            None,
            &json!({"a":1}),
        );
        let b = stable_tool_call_material(
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
}
