//! Tool executor — guardrails → pre-hooks → execute → post-hooks pipeline.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::core::events::{BaseEvent, HookResult as EventHookResult, TronEvent};
use crate::core::messages::Provider;
use crate::core::messages::ToolCall;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation,
    InvocationId, TraceId,
};
use crate::runtime::context::local_policy;
use crate::runtime::guardrails::{EvaluationContext, GuardrailEngine};
use crate::runtime::hooks::engine::HookEngine;
use crate::runtime::hooks::types::{HookAction, HookContext};
use crate::tools::capability_runtime::{
    RuntimeToolExecution, insert_runtime_tool_execution, remove_runtime_tool_execution,
};
use crate::tools::capability_surface::{EngineToolTarget, ResolvedToolSurface};
use crate::tools::traits::ToolContext;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::orchestrator::tool_abort_registry::{ToolAbortGuard, ToolAbortRegistry};
use crate::runtime::types::ToolExecutionResult;

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

/// Shared dependencies for tool execution (extracted to reduce parameter count).
pub struct ToolExecutionContext<'a> {
    /// Live engine-catalog tool surface resolved for this turn.
    pub tool_surface: &'a ResolvedToolSurface,
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
    pub process_manager: Option<&'a Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    /// Optional unified job manager for process + subagent lifecycle.
    pub job_manager: Option<&'a Arc<dyn crate::tools::traits::JobManagerOps>>,
    /// Optional output buffer registry for on-demand process output streaming.
    pub output_buffer_registry:
        Option<&'a Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    /// Optional per-session sequence counter for monotonic event ordering.
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Provider type of the active model. Used to enforce the local-model
    /// tool allow-list at the execution boundary (see `local_policy`).
    pub provider_type: Provider,
    /// Optional execution spec selected by the current session profile.
    pub execution_spec: Option<&'a crate::core::profile::AgentExecutionSpec>,
    /// Optional persister for durable progress events. When `Some`, long-running
    /// tools can call `ctx.emit_progress(...)` to surface incremental status
    /// (Bash heartbeat, WebFetch bytes, subagent turn count) as persisted
    /// `tool.progress` events visible through live stream and reconstruction.
    pub event_persister:
        Option<&'a Arc<crate::runtime::orchestrator::event_persister::EventPersister>>,
    /// Turn number this tool call belongs to. Copied into each progress event
    /// so iOS can attribute progress after disconnect/reconnect.
    pub turn: i64,
    /// Optional per-tool abort registry. When `Some`, each tool call registers
    /// a child `CancellationToken` so `agent.abortTool` can cancel a single
    /// tool without aborting the whole turn. When `None`, the turn-level
    /// `cancel` token is passed through unchanged.
    pub tool_abort_registry: Option<&'a Arc<ToolAbortRegistry>>,
    /// Optional engine host for routing actual tool execution through
    /// canonical `tool::*` functions after runtime guardrails and hooks.
    pub engine_host: Option<&'a EngineHostHandle>,
    /// Stable run id used for model tool-call idempotency.
    pub run_id: Option<&'a str>,
    /// Trace inherited from the owning agent run-turn invocation.
    pub trace_id: Option<&'a TraceId>,
    /// Parent invocation inherited from the owning agent run-turn invocation.
    pub parent_invocation_id: Option<&'a InvocationId>,
}

/// Execute a single tool call through the full pipeline.
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

    // 1. Resolve the model tool name through the live engine catalog captured
    // at the provider request boundary.
    let engine_target = ctx.tool_surface.targets_by_name.get(&tool_name);
    if engine_target.is_none() {
        error!(tool_name, "tool not found");
        return ToolExecutionResult {
            tool_call_id,
            result: crate::core::tools::error_result(format!("Tool not found: {tool_name}")),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn: false,
            is_interactive: false,
        };
    }

    let stops_turn = engine_target.is_some_and(|target| target.stops_turn);
    let is_interactive = engine_target.is_some_and(|target| target.is_interactive);

    // 1a. Provider-scoped allow-list. Local models only see a subset of tool
    // schemas; if the model hallucinates a call to a hidden tool, refuse
    // execution here so the gate is enforced at the execution boundary (not
    // only at schema-rendering time).
    let spec = ctx
        .execution_spec
        .expect("ToolExecutionContext.execution_spec must come from the session execution plan");
    let context_policy =
        local_policy::ContextPolicy::from_entrypoint_with_spec(ctx.provider_type, spec, "main");
    let allowed_tools = context_policy.tool_filter();
    if context_policy.is_local()
        && let Some(allowed) = allowed_tools.as_ref()
        && !allowed.iter().any(|allowed| allowed == &tool_name)
    {
        warn!(tool_name, "tool not available for local model");
        return ToolExecutionResult {
            tool_call_id,
            result: crate::core::tools::error_result(format!(
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

    // 2. Evaluate guardrails (synchronous)
    if let Some(guardrail_engine) = ctx.guardrails {
        let eval_ctx = EvaluationContext {
            tool_name: tool_name.clone(),
            tool_arguments: Value::Object(tool_call.arguments.clone()),
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
                    result: crate::core::tools::error_result(reason),
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
    let mut effective_args = Value::Object(tool_call.arguments.clone());
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
                    base: BaseEvent::now(session_id),
                    hook_names: vec![],
                    hook_event: "PreToolUse".into(),
                    tool_name: Some(tool_name.clone()),
                    tool_call_id: Some(tool_call_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: BaseEvent::now(session_id),
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
                    base: BaseEvent::now(session_id),
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
                base: BaseEvent::now(session_id),
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
                    result: crate::core::tools::error_result(reason),
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

    // 4. Emit ToolExecutionStart
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(
            TronEvent::ToolExecutionStart {
                base: BaseEvent::now(session_id),
                tool_call_id: tool_call_id.clone(),
                tool_name: tool_name.clone(),
                arguments: effective_args.as_object().cloned(),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::ToolExecutionStart {
            base: BaseEvent::now(session_id),
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            arguments: effective_args.as_object().cloned(),
        });
    }
    debug!(
        tool_name,
        tool_call_id, session_id, "tool execution started"
    );

    // 5. Execute tool with streaming output channel
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

    let (output_tx, mut output_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let tool_ctx = ToolContext {
        tool_call_id: tool_call_id.clone(),
        session_id: session_id.to_owned(),
        working_directory: working_directory.to_owned(),
        cancellation: per_tool_cancel.clone(),
        subagent_depth: ctx.subagent_depth,
        subagent_max_depth: ctx.subagent_max_depth,
        workspace_id: ctx.workspace_id.map(String::from),
        output_tx: Some(output_tx),
        process_manager: ctx.process_manager.map(Arc::clone),
        job_manager: ctx.job_manager.map(Arc::clone),
        output_buffer_registry: ctx.output_buffer_registry.map(Arc::clone),
        event_emitter: Some(Arc::clone(ctx.emitter)),
        event_persister: ctx.event_persister.map(Arc::clone),
        turn: ctx.turn,
        all_tool_names: ctx.tool_surface.all_tool_names.clone(),
    };

    // Spawn a task to forward streaming output chunks as ToolExecutionUpdate events
    let stream_emitter = ctx.emitter.clone();
    let stream_tool_call_id = tool_call_id.clone();
    let stream_session_id = session_id.to_owned();
    let stream_handle = tokio::spawn(async move {
        while let Some(chunk) = output_rx.recv().await {
            let _ = stream_emitter.emit(TronEvent::ToolExecutionUpdate {
                base: BaseEvent::now(&stream_session_id),
                tool_call_id: stream_tool_call_id.clone(),
                update: chunk,
            });
        }
    });

    let tool_result = if per_tool_cancel.is_cancelled() {
        crate::core::tools::error_result("Operation cancelled")
    } else if let (Some(engine_host), Some(target)) = (ctx.engine_host, engine_target) {
        execute_tool_via_engine(
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
            effective_args,
            tool_ctx.clone(),
        )
        .await
    } else {
        return ToolExecutionResult {
            tool_call_id,
            result: crate::core::tools::error_result(format!(
                "Engine host is required to execute tool '{tool_name}'"
            )),
            duration_ms: duration_ceil_ms(start.elapsed()),
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            stops_turn,
            is_interactive,
        };
    };
    // Drop the ToolContext's sender so the stream_handle can complete
    drop(tool_ctx);
    let _ = stream_handle.await;

    let duration_ms = duration_ceil_ms(start.elapsed());

    // Record tool metrics
    counter!("tool_executions_total", "tool" => tool_name.clone()).increment(1);
    histogram!("tool_execution_duration_seconds", "tool" => tool_name.clone())
        .record(start.elapsed().as_secs_f64());

    // 6. Emit ToolExecutionEnd
    if let Some(counter) = ctx.sequence_counter {
        let _ = ctx.emitter.emit_sequenced(
            TronEvent::ToolExecutionEnd {
                base: BaseEvent::now(session_id),
                tool_call_id: tool_call_id.clone(),
                tool_name: tool_name.clone(),
                duration: duration_ms,
                is_error: tool_result.is_error,
                result: Some(tool_result.clone()),
            },
            counter,
        );
    } else {
        let _ = ctx.emitter.emit(TronEvent::ToolExecutionEnd {
            base: BaseEvent::now(session_id),
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            duration: duration_ms,
            is_error: tool_result.is_error,
            result: Some(tool_result.clone()),
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
                    base: BaseEvent::now(session_id),
                    hook_names: vec![],
                    hook_event: "PostToolUse".into(),
                    tool_name: Some(tool_name.clone()),
                    tool_call_id: Some(tool_call_id.clone()),
                },
                counter,
            );
        } else {
            let _ = ctx.emitter.emit(TronEvent::HookTriggered {
                base: BaseEvent::now(session_id),
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
                        base: BaseEvent::now(&sid),
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

#[allow(clippy::too_many_arguments)]
async fn execute_tool_via_engine(
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
    effective_args: Value,
    tool_ctx: ToolContext,
) -> crate::core::tools::TronToolResult {
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
    let idempotency_key = format!("model-tool-call:v1:{fingerprint}");
    let function_id = target.function_id.clone();
    let actor_id = match ActorId::new(format!("agent:{session_id}")) {
        Ok(id) => id,
        Err(error) => return crate::core::tools::error_result(error.to_string()),
    };
    let grant_id = match AuthorityGrantId::new("agent-tool-runtime") {
        Ok(id) => id,
        Err(error) => return crate::core::tools::error_result(error.to_string()),
    };
    let trace_id = inherited_trace_id
        .cloned()
        .unwrap_or_else(TraceId::generate);
    let mut causal_context = CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("tool.read")
        .with_scope("tool.write")
        .with_scope("tool.invoke")
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
    let payload = effective_args;
    let runtime_execution = RuntimeToolExecution {
        tool_name: tool_name.to_owned(),
        params: payload.clone(),
        context: tool_ctx,
    };
    let invocation = Invocation::new_sync(function_id.clone(), payload, causal_context)
        .expecting_revision(target.function.revision);
    let runtime_invocation_id = invocation.id.to_string();
    if function_id.namespace() == "tool" {
        insert_runtime_tool_execution(runtime_invocation_id.clone(), runtime_execution);
    }
    let result = engine_host.invoke(invocation.clone()).await;
    remove_runtime_tool_execution(&runtime_invocation_id);

    if let Some(error) = result.error {
        return crate::core::tools::error_result(format!(
            "Engine tool invocation failed for {function_id}: {error}"
        ));
    }
    let Some(value) = result.value else {
        return crate::core::tools::error_result(format!(
            "Engine tool invocation returned no result for {function_id}"
        ));
    };
    serde_json::from_value(value).unwrap_or_else(|error| {
        crate::core::tools::error_result(format!(
            "Engine tool invocation returned invalid tool result for {function_id}: {error}"
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
    use crate::core::tools::ToolResultBody;
    use crate::engine::{
        AuthorityRequirement, EffectClass, FunctionDefinition, FunctionId, RiskLevel,
        VisibilityScope, WorkerDefinition, WorkerId, WorkerKind,
    };
    use crate::runtime::agent::event_emitter::EventEmitter;
    use crate::tools::capability_surface::{
        EngineToolTarget, ResolvedToolSurface, ToolSurfacePolicy, resolve_provider_tools,
    };
    use crate::tools::traits::ExecutionMode;
    use async_trait::async_trait;
    use parking_lot::Mutex;
    use std::collections::{BTreeMap, HashSet};

    fn default_execution_spec() -> crate::core::profile::AgentExecutionSpec {
        let tempdir = tempfile::tempdir().expect("profile tempdir");
        let home = tempdir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).expect("seed profile home");
        let profile =
            crate::core::profile::resolve_profile_at(&home, crate::core::profile::NORMAL_PROFILE)
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
        let function_id = FunctionId::new("tool::echo").expect("function id");
        let function = FunctionDefinition::new(
            function_id.clone(),
            WorkerId::new("tool").expect("worker id"),
            "Echo".to_owned(),
            VisibilityScope::System,
            EffectClass::PureRead,
        )
        .with_risk(RiskLevel::Low)
        .with_required_authority(AuthorityRequirement::scope("tool.read"));
        let target = EngineToolTarget {
            model_tool_name: "Echo".to_owned(),
            function_id,
            function,
            stops_turn: true,
            is_interactive: false,
            execution_mode: ExecutionMode::Parallel,
        };
        let mut targets_by_name = BTreeMap::new();
        let _ = targets_by_name.insert("Echo".to_owned(), target);
        ResolvedToolSurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            tools: Vec::new(),
            targets_by_name,
            all_tool_names: vec!["Echo".to_owned()],
            turn_stopping_tools: HashSet::from(["Echo".to_owned()]),
        }
    }

    fn tool_exec_ctx<'a>(
        surface: &'a ResolvedToolSurface,
        emitter: &'a Arc<EventEmitter>,
        cancel: &'a CancellationToken,
        execution_spec: &'a crate::core::profile::AgentExecutionSpec,
    ) -> ToolExecutionContext<'a> {
        ToolExecutionContext {
            tool_surface: surface,
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
            event_persister: None,
            turn: 1,
            tool_abort_registry: None,
            engine_host: None,
            run_id: Some("run-1"),
            trace_id: None,
            parent_invocation_id: None,
        }
    }

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
        let call = ToolCall::new("tc1", "Echo", Default::default());
        let result = execute_tool(&call, "s1", "/tmp", &ctx).await;
        assert!(result.result.is_error.unwrap_or(false));
        assert!(result.stops_turn);
    }

    #[tokio::test]
    async fn model_tool_call_invokes_builtin_tool_through_engine() {
        let server = crate::server::shared::test_support::make_test_context();
        let spec = default_execution_spec();
        let context_policy =
            crate::runtime::context::local_policy::ContextPolicy::from_provider_with_spec(
                Provider::Anthropic,
                &spec,
            );
        let surface = resolve_provider_tools(
            &server.engine_host,
            "s1",
            None,
            Provider::Anthropic,
            &context_policy,
            &ToolSurfacePolicy::default(),
        )
        .await
        .expect("provider tool surface");
        assert!(surface.targets_by_name.contains_key("Read"));

        let tempdir = tempfile::tempdir().expect("tool tempdir");
        let file_path = tempdir.path().join("note.txt");
        std::fs::write(&file_path, "hello from engine").expect("write fixture");

        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let mut ctx = tool_exec_ctx(&surface, &emitter, &cancel, &spec);
        ctx.engine_host = Some(&server.engine_host);

        let mut args = serde_json::Map::new();
        args.insert(
            "file_path".to_owned(),
            Value::String(file_path.to_string_lossy().into_owned()),
        );
        let call = ToolCall::new("tc1", "Read", args);
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
                    WorkerId::new("tool").expect("worker id"),
                    WorkerKind::InProcess,
                    ActorId::new("tool-owner").expect("actor id"),
                    AuthorityGrantId::new("tool-grant").expect("grant id"),
                )
                .with_namespace_claim("tool"),
                false,
            )
            .await
            .expect("register worker");

        let captured = Arc::new(Mutex::new(None));
        let function_id = FunctionId::new("tool::capture").expect("function id");
        let function = FunctionDefinition::new(
            function_id.clone(),
            WorkerId::new("tool").expect("worker id"),
            "Capture tool invocation".to_owned(),
            VisibilityScope::System,
            EffectClass::IdempotentWrite,
        )
        .with_risk(RiskLevel::Medium)
        .with_required_authority(AuthorityRequirement::scope("tool.write"))
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
            "Capture".to_owned(),
            EngineToolTarget {
                model_tool_name: "Capture".to_owned(),
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
            all_tool_names: vec!["Capture".to_owned()],
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
        let call = ToolCall::new("tool-call-1", "Capture", args);
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
            "tool-call-1",
            "Capture",
            "/tmp/worktree",
            None,
            &json!({"value": "hello"}),
        );
        let expected_key = format!(
            "model-tool-call:v1:{}",
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
