//! ModelCapability executor — guardrails → pre-hooks → execute → post-hooks pipeline.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::domains::agent::runner::context::local_policy;
use crate::domains::agent::runner::guardrails::{EvaluationContext, GuardrailEngine};
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::hooks::types::{HookAction, HookContext};
use crate::domains::capability::registry::CapabilitySearchPolicy;
use crate::domains::capability_support::implementations::primitive_surface::{
    EngineCapabilityTarget, PrimitiveSurfacePolicy, ResolvedCapabilitySurface,
    capability_execution_policy_scopes,
};
use crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation,
    InvocationId, TraceId,
};
use crate::shared::events::{
    BaseEvent, CapabilityEventIdentity, HookResult as EventHookResult, TronEvent,
};
use crate::shared::messages::CapabilityInvocationDraft;
use crate::shared::messages::Provider;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::{
    InvocationAbortGuard, InvocationAbortRegistry,
};
use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;

/// Convert a `Duration` to milliseconds, rounding up (ceiling).
///
/// `Duration::as_millis()` truncates sub-millisecond values to 0, which makes
/// fast capabilities (file glob, `SQLite` lookup) report "0ms". This function ensures
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

fn presentation_theme_color(function: &crate::engine::FunctionDefinition) -> Option<String> {
    function
        .metadata
        .get("presentationHints")
        .and_then(|value| value.get("themeColor"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn details_theme_color(details: &Value) -> Option<String> {
    details
        .get("presentationHints")
        .and_then(|value| value.get("themeColor"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
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
        theme_color: presentation_theme_color(function),
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
    let binding = details.get("bindingDecision");
    CapabilityEventIdentity {
        model_primitive_name: Some(model_primitive_name.to_owned()),
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
        theme_color: details_theme_color(details).or_else(|| base_identity.theme_color.clone()),
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
pub struct CapabilityInvocationExecutionContext<'a> {
    /// Live engine-catalog capability surface resolved for this turn.
    pub primitive_surface: &'a ResolvedCapabilitySurface,
    /// Profile/session primitive policy that gates the provider-facing primitives.
    pub primitive_surface_policy: &'a PrimitiveSurfacePolicy,
    /// Profile/session capability execution policy that gates worker contracts.
    pub capability_execution_policy: &'a crate::shared::profile::CapabilityExecutionPolicySpec,
    /// Optional guardrail engine for pre-execution validation.
    pub guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Optional hook engine for pre/post capability-invocation hooks.
    pub hooks: &'a Option<Arc<HookEngine>>,
    /// Event emitter for capability lifecycle events.
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
    /// capability allow-list at the execution boundary (see `local_policy`).
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
    /// a child `CancellationToken` so `agent.abortCapabilityInvocation` can cancel one capability
    /// primitive without aborting the whole turn. When `None`, the turn-level
    /// `cancel` token is passed through unchanged.
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
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

    // 1. Resolve the model capability id through the live engine catalog captured
    // at the provider request boundary.
    let engine_target = ctx
        .primitive_surface
        .targets_by_name
        .get(&model_primitive_name);
    if engine_target.is_none() {
        error!(model_primitive_name, "capability primitive not found");
        return CapabilityInvocationExecutionResult {
            invocation_id,
            result: crate::shared::model_capabilities::error_result(format!(
                "Capability primitive not found: {model_primitive_name}"
            )),
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
        &model_primitive_name,
        engine_target.expect("checked above"),
        ctx.primitive_surface.catalog_revision.0,
        ctx.trace_id,
        ctx.parent_invocation_id,
    );

    // 1a. Provider-scoped allow-list. Local models only see a subset of
    // capability schemas; if the model hallucinates a hidden primitive, refuse
    // execution here so the gate is enforced at the execution boundary (not
    // only at schema-rendering time).
    let spec = ctx
        .execution_spec
        .expect("CapabilityInvocationExecutionContext.execution_spec must come from the session execution plan");
    let context_policy =
        local_policy::ContextPolicy::from_entrypoint_with_spec(ctx.provider_type, spec, "main");
    let allowed_primitives = context_policy.primitive_filter();
    if context_policy.is_local()
        && let Some(allowed) = allowed_primitives.as_ref()
        && !allowed
            .iter()
            .any(|allowed| allowed == &model_primitive_name)
    {
        warn!(
            model_primitive_name,
            "capability not available for local model"
        );
        return CapabilityInvocationExecutionResult {
            invocation_id,
            result: crate::shared::model_capabilities::error_result(format!(
                "Capability primitive '{model_primitive_name}' is not available for local models. Use one of: {}.",
                allowed.join(", ")
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn: false,
            is_interactive: false,
        };
    }

    let mut effective_args = Value::Object(capability_invocation.arguments.clone());

    // 2. Evaluate guardrails (synchronous)
    if let Some(guardrail_engine) = ctx.guardrails {
        let guardrail_model_primitive_name =
            guardrail_capability_id(&model_primitive_name, &effective_args);
        let guardrail_arguments =
            guardrail_capability_arguments(&model_primitive_name, &effective_args);
        let eval_ctx = EvaluationContext {
            model_primitive_name: guardrail_model_primitive_name,
            capability_arguments: guardrail_arguments,
            session_id: Some(session_id.to_owned()),
            invocation_id: Some(invocation_id.clone()),
        };
        {
            let mut engine = guardrail_engine.lock();
            let eval = engine.evaluate(&eval_ctx);
            if eval.blocked {
                warn!(model_primitive_name, "blocked by guardrail");
                let reason = eval
                    .block_reason
                    .unwrap_or_else(|| "Blocked by guardrail".into());
                return CapabilityInvocationExecutionResult {
                    invocation_id,
                    result: crate::shared::model_capabilities::error_result(reason),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: false,
                    blocked_by_guardrail: true,
                    stops_turn,
                    is_interactive,
                };
            }
        }
    }

    // 3. Execute PreCapabilityInvocation hooks (blocking, sequential)
    if let Some(hook_engine) = ctx.hooks {
        let hook_ctx = HookContext::PreCapabilityInvocation {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            model_primitive_name: model_primitive_name.clone(),
            capability_arguments: effective_args.clone(),
            invocation_id: invocation_id.clone(),
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookTriggered {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PreCapabilityInvocation".into(),
                    model_primitive_name: Some(model_primitive_name.clone()),
                    invocation_id: Some(invocation_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PreCapabilityInvocation".into(),
                model_primitive_name: Some(model_primitive_name.clone()),
                invocation_id: Some(invocation_id.clone()),
            });
        }
        let result = hook_engine.execute(&hook_ctx).await;
        let event_result = match result.action {
            HookAction::Block => EventHookResult::Block,
            HookAction::Modify => EventHookResult::Modify,
            // AddContext is a no-op on PreCapabilityInvocation (capabilities do not accept
            // context injection). Map to Continue so the event wire
            // format is unchanged.
            HookAction::Continue | HookAction::AddContext => EventHookResult::Continue,
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookCompleted {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PreCapabilityInvocation".into(),
                    result: event_result,
                    duration: None,
                    reason: result.reason.clone(),
                    model_primitive_name: Some(model_primitive_name.clone()),
                    invocation_id: Some(invocation_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookCompleted {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PreCapabilityInvocation".into(),
                result: event_result,
                duration: None,
                reason: result.reason.clone(),
                model_primitive_name: Some(model_primitive_name.clone()),
                invocation_id: Some(invocation_id.clone()),
            });
        }
        match result.action {
            HookAction::Block => {
                warn!(
                    model_primitive_name,
                    "blocked by PreCapabilityInvocation hook"
                );
                let reason = result
                    .reason
                    .unwrap_or_else(|| "Blocked by PreCapabilityInvocation hook".into());
                return CapabilityInvocationExecutionResult {
                    invocation_id,
                    result: crate::shared::model_capabilities::error_result(reason),
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
            // AddContext has no meaning on a PreCapabilityInvocation hook (capabilities
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
                invocation_id: invocation_id.clone(),
                model_primitive_name: model_primitive_name.clone(),
                arguments: effective_args.as_object().cloned(),
                capability_identity: primitive_identity.clone(),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::CapabilityInvocationStarted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            model_primitive_name: model_primitive_name.clone(),
            arguments: effective_args.as_object().cloned(),
            capability_identity: primitive_identity.clone(),
        });
    }
    if model_primitive_name == "execute" {
        let (requested_contract_id, requested_implementation_id, requested_function_id) =
            execution_request_target(&effective_args);
        if requested_implementation_id.is_none() && requested_function_id.is_none() {
            let event = TronEvent::CapabilityResolution {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                invocation_id: invocation_id.clone(),
                model_primitive_name: model_primitive_name.clone(),
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
        model_primitive_name,
        invocation_id, session_id, "capability invocation started"
    );

    // 5. Execute the capability primitive.
    //
    // When a `invocation_abort_registry` is present, derive a child `CancellationToken`
    // scoped to this single call. `agent.abortCapabilityInvocation` cancels the child; parent
    // (turn-level) cancellation still propagates to every child automatically.
    // The RAII guard ensures the registry entry is removed on every exit path
    // (normal return, error, panic).
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
    } else if let (Some(engine_host), Some(target)) = (ctx.engine_host, engine_target) {
        let mut execution_policy_scopes = ctx.primitive_surface_policy.primitive_policy_scopes();
        execution_policy_scopes.extend(capability_execution_policy_scopes(
            ctx.capability_execution_policy,
        ));
        match primitive_runtime_metadata(ctx, &context_policy) {
            Ok(runtime_metadata) => {
                execute_capability_primitive_via_engine(
                    engine_host,
                    target,
                    &model_primitive_name,
                    &invocation_id,
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
            Err(error) => crate::shared::model_capabilities::error_result(error),
        }
    } else {
        return CapabilityInvocationExecutionResult {
            invocation_id,
            result: crate::shared::model_capabilities::error_result(format!(
                "Engine host is required to execute capability primitive '{model_primitive_name}'"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
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

    // Record capability invocation metrics
    counter!("capability_invocations_total", "capability" => model_primitive_name.clone())
        .increment(1);
    histogram!("capability_invocation_duration_seconds", "capability" => model_primitive_name.clone())
        .record(start.elapsed().as_secs_f64());

    // 6. Emit CapabilityInvocationCompleted
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(
            TronEvent::CapabilityInvocationCompleted {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                invocation_id: invocation_id.clone(),
                model_primitive_name: model_primitive_name.clone(),
                duration: duration_ms,
                is_error: capability_result.is_error,
                result: Some(capability_result.clone()),
                capability_identity: resolved_identity.clone(),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::CapabilityInvocationCompleted {
            base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
            invocation_id: invocation_id.clone(),
            model_primitive_name: model_primitive_name.clone(),
            duration: duration_ms,
            is_error: capability_result.is_error,
            result: Some(capability_result.clone()),
            capability_identity: resolved_identity,
        });
    }
    debug!(capability = %model_primitive_name, duration_ms, "capability invocation completed");

    // 7. Execute PostCapabilityInvocation hooks (background, fire-and-forget)
    if let Some(hook_engine) = ctx.hooks {
        let hook_ctx = HookContext::PostCapabilityInvocation {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            model_primitive_name: model_primitive_name.clone(),
            invocation_id: invocation_id.clone(),
            result: serde_json::to_value(&capability_result).unwrap_or_default(),
            duration_ms,
        };
        if let Some(counter) = ctx.sequence_counter {
            let _ = ctx.emitter.emit_sequenced(
                TronEvent::HookTriggered {
                    base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                    hook_names: vec![],
                    hook_event: "PostCapabilityInvocation".into(),
                    model_primitive_name: Some(model_primitive_name.clone()),
                    invocation_id: Some(invocation_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: traced_base(session_id, ctx.trace_id, ctx.parent_invocation_id),
                hook_names: vec![],
                hook_event: "PostCapabilityInvocation".into(),
                model_primitive_name: Some(model_primitive_name.clone()),
                invocation_id: Some(invocation_id.clone()),
            });
        }
        // PostCapabilityInvocation hooks run fire-and-forget with a 30s timeout to prevent leaks.
        let engine = hook_engine.clone();
        let emitter_bg = ctx.emitter.clone();
        let sid = session_id.to_owned();
        let tn = model_primitive_name.clone();
        let tcid = invocation_id.clone();
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
                        // AddContext on PostCapabilityInvocation is a no-op — a
                        // completed capability has no prompt surface to
                        // inject context into.
                        HookAction::Continue | HookAction::AddContext => EventHookResult::Continue,
                    };
                    let _ = emitter_bg.emit(TronEvent::HookCompleted {
                        base: BaseEvent::now(&sid)
                            .with_trace_context(hook_trace_id, hook_parent_invocation_id),
                        hook_names: vec![],
                        hook_event: "PostCapabilityInvocation".into(),
                        result: event_result,
                        duration: None,
                        reason: bg_result.reason.clone(),
                        model_primitive_name: Some(tn),
                        invocation_id: Some(tcid),
                    });
                }
                Err(_) => {
                    warn!(
                        model_primitive_name = %tn,
                        invocation_id = %tcid,
                        "PostCapabilityInvocation hook timed out after 30s"
                    );
                }
            }
        });
    }

    CapabilityInvocationExecutionResult {
        invocation_id,
        result: capability_result,
        duration_ms,
        blocked_by_hook: false,
        blocked_by_guardrail: false,
        stops_turn: stops_turn || result_stops_turn,
        is_interactive,
    }
}

fn guardrail_capability_id(model_primitive_name: &str, args: &Value) -> String {
    if model_primitive_name != "execute" {
        return model_primitive_name.to_owned();
    }
    [
        "contractId",
        "implementationId",
        "functionId",
        "capabilityId",
    ]
    .iter()
    .find_map(|key| args.get(key).and_then(Value::as_str))
    .unwrap_or(model_primitive_name)
    .to_owned()
}

fn guardrail_capability_arguments(model_primitive_name: &str, args: &Value) -> Value {
    if model_primitive_name == "execute"
        && let Some(payload) = args.get("payload")
    {
        return payload.clone();
    }
    args.clone()
}

fn primitive_runtime_metadata(
    ctx: &CapabilityInvocationExecutionContext<'_>,
    context_policy: &local_policy::ContextPolicy,
) -> Result<Vec<(String, String)>, String> {
    let spec = ctx
        .execution_spec
        .ok_or_else(|| "capability primitive runtime requires an execution spec".to_owned())?;
    let entrypoint = spec
        .entrypoints
        .get("main")
        .ok_or_else(|| "capability primitive runtime requires entrypoints.main".to_owned())?;
    let capability_execution_policy_id = context_policy
        .capability_execution_policy_id()
        .unwrap_or(entrypoint.capability_execution_policy.as_str());
    let capability_execution_policy = spec
        .capability_execution_policy(capability_execution_policy_id)
        .ok_or_else(|| {
            format!("missing capability execution policy '{capability_execution_policy_id}'")
        })?;
    let search_policy_id = capability_execution_policy
        .search_policy
        .as_deref()
        .unwrap_or("hybridLocal");
    let search_policy = spec
        .capability_search_policy(search_policy_id)
        .ok_or_else(|| format!("missing capability search policy '{search_policy_id}'"))?;
    let context_primer_policy_id = capability_execution_policy
        .context_primer_policy
        .as_deref()
        .unwrap_or("coreFirstParty");
    let serialized_search_policy =
        serde_json::to_string(&CapabilitySearchPolicy::from_profile(search_policy))
            .map_err(|error| format!("serialize capability search policy: {error}"))?;
    let mut metadata = vec![
        (
            "capability.executionPolicyId".to_owned(),
            capability_execution_policy_id.to_owned(),
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
    execution_policy_scopes: &[String],
    runtime_metadata: &[(String, String)],
    effective_args: Value,
) -> crate::shared::model_capabilities::CapabilityResult {
    let material = stable_capability_invocation_material(
        run_id,
        session_id,
        turn,
        invocation_id,
        model_primitive_name,
        working_directory,
        workspace_id,
        &effective_args,
    );
    let fingerprint = sha256_hex(material.as_bytes());
    let idempotency_key = format!("model-capability-invocation:v1:{fingerprint}");
    let function_id = target.function_id.clone();
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
        "invocationId": invocation_id,
        "modelPrimitiveName": model_primitive_name,
        "workingDirectory": working_directory,
        "workspaceId": workspace_id,
        "arguments": effective_args,
    });
    serde_json::to_string(&payload).unwrap_or_else(|_| format!(
        "{:?}:{session_id}:{turn}:{invocation_id}:{model_primitive_name}:{working_directory}:{workspace_id:?}:{effective_args}",
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
    use crate::domains::capability_support::implementations::primitive_surface::{
        EngineCapabilityTarget, PrimitiveSurfacePolicy, ResolvedCapabilitySurface,
        resolve_provider_capabilities,
    };
    use crate::domains::capability_support::implementations::traits::ExecutionMode;
    use crate::engine::{
        AuthorityRequirement, EffectClass, FunctionDefinition, FunctionId, RiskLevel,
        VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
    };
    use crate::shared::content::CapabilityResultContent;
    use crate::shared::model_capabilities::CapabilityResultBody;
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
        execution_spec: &'a crate::shared::profile::AgentExecutionSpec,
    ) -> CapabilityInvocationExecutionContext<'a> {
        CapabilityInvocationExecutionContext {
            primitive_surface: surface,
            primitive_surface_policy: &DEFAULT_PRIMITIVE_SURFACE_POLICY,
            capability_execution_policy: &execution_spec.capability_execution_policies["default"],
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
            invocation_abort_registry: None,
            engine_host: None,
            run_id: Some("run-1"),
            trace_id: None,
            parent_invocation_id: None,
        }
    }

    static DEFAULT_PRIMITIVE_SURFACE_POLICY: std::sync::LazyLock<PrimitiveSurfacePolicy> =
        std::sync::LazyLock::new(PrimitiveSurfacePolicy::default);

    #[tokio::test]
    async fn unknown_model_primitive_fails_before_execution() {
        let surface = empty_surface();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let spec = default_execution_spec();
        let ctx = capability_exec_ctx(&surface, &emitter, &cancel, &spec);
        let call = CapabilityInvocationDraft::new("tc1", "Missing", Default::default());
        let result = execute_capability_invocation(&call, "s1", "/tmp", &ctx).await;
        assert!(result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn catalog_target_requires_engine_host_for_execution() {
        let surface = surface_with_echo();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let spec = default_execution_spec();
        let ctx = capability_exec_ctx(&surface, &emitter, &cancel, &spec);
        let call = CapabilityInvocationDraft::new("tc1", "execute", Default::default());
        let result = execute_capability_invocation(&call, "s1", "/tmp", &ctx).await;
        assert!(result.result.is_error.unwrap_or(false));
        assert!(result.stops_turn);
    }

    #[tokio::test]
    async fn model_capability_invocation_invokes_capability_primitive_through_engine() {
        let server = crate::shared::server::test_support::make_test_context();
        let spec = default_execution_spec();
        let context_policy =
            crate::domains::agent::runner::context::local_policy::ContextPolicy::from_provider_with_spec(
                Provider::Anthropic,
                &spec,
            );
        let surface = resolve_provider_capabilities(
            &server.engine_host,
            "s1",
            None,
            Provider::Anthropic,
            &context_policy,
            &PrimitiveSurfacePolicy::default(),
        )
        .await
        .expect("provider capability surface");
        assert_eq!(
            surface.all_model_capability_ids,
            vec!["search", "inspect", "execute"]
        );
        assert!(surface.targets_by_name.contains_key("execute"));

        let tempdir = tempfile::tempdir().expect("capability tempdir");
        let file_path = tempdir.path().join("note.txt");
        std::fs::write(&file_path, "hello from engine").expect("write fixture");

        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel, &spec);
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
        let call = CapabilityInvocationDraft::new("tc1", "execute", args);
        let result = execute_capability_invocation(
            &call,
            "s1",
            tempdir.path().to_str().expect("utf8 tempdir"),
            &ctx,
        )
        .await;

        assert_eq!(result.result.is_error, None);
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
    async fn engine_capability_result_stop_turn_pauses_runner_even_when_target_is_not_static_stop()
    {
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
        let spec = default_execution_spec();
        let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel, &spec);
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
        let spec = default_execution_spec();
        let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel, &spec);
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
}
