//! Tool executor — guardrails → pre-hooks → execute → post-hooks pipeline.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::{Duration, Instant};

use crate::core::events::{BaseEvent, HookResult as EventHookResult, TronEvent};
use crate::core::messages::Provider;
use crate::core::messages::ToolCall;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle, Invocation, TraceId,
};
use crate::runtime::context::local_policy;
use crate::runtime::guardrails::{EvaluationContext, GuardrailEngine};
use crate::runtime::hooks::engine::HookEngine;
use crate::runtime::hooks::types::{HookAction, HookContext};
use crate::tools::capability_runtime::{
    RuntimeToolExecution, insert_runtime_tool_execution, remove_runtime_tool_execution,
};
use crate::tools::capability_surface::{EngineToolTarget, resolve_model_tool_target};
use crate::tools::registry::ToolRegistry;
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
    /// Registered tools available for execution.
    pub registry: &'a ToolRegistry,
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

    // 1. Resolve the model tool name through the live engine catalog. The
    // registry remains a temporary implementation/policy backing for built-ins,
    // but the executable capability and schema contract come from the catalog.
    let registry_tool = ctx.registry.get(&tool_name);
    let engine_target = if let Some(engine_host) = ctx.engine_host {
        match resolve_model_tool_target(
            engine_host,
            ctx.registry,
            session_id,
            ctx.workspace_id,
            &tool_name,
        )
        .await
        {
            Ok(target) => target,
            Err(error) => {
                error!(tool_name, error = %error, "failed to resolve engine tool target");
                return ToolExecutionResult {
                    tool_call_id,
                    result: crate::core::tools::error_result(format!(
                        "Tool catalog resolution failed for {tool_name}: {error}"
                    )),
                    duration_ms: duration_ceil_ms(start.elapsed()),
                    blocked_by_hook: false,
                    blocked_by_guardrail: false,
                    stops_turn: false,
                    is_interactive: false,
                };
            }
        }
    } else {
        None
    };

    if registry_tool.is_none() && engine_target.is_none() {
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

    let stops_turn = registry_tool
        .as_ref()
        .map(|tool| tool.stops_turn())
        .or_else(|| engine_target.as_ref().map(|target| target.stops_turn))
        .unwrap_or(false);
    let is_interactive = registry_tool
        .as_ref()
        .map(|tool| tool.is_interactive())
        .or_else(|| engine_target.as_ref().map(|target| target.is_interactive))
        .unwrap_or(false);

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
        all_tool_names: ctx.registry.names(),
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
    } else if let (Some(engine_host), Some(target)) = (ctx.engine_host, engine_target.as_ref()) {
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
            effective_args,
            tool_ctx.clone(),
        )
        .await
    } else {
        #[cfg(not(test))]
        {
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
        }
        #[cfg(test)]
        let Some(tool) = registry_tool else {
            return ToolExecutionResult {
                tool_call_id,
                result: crate::core::tools::error_result(format!(
                    "Tool '{tool_name}' is not executable without an engine catalog target"
                )),
                duration_ms: duration_ceil_ms(start.elapsed()),
                blocked_by_hook: false,
                blocked_by_guardrail: false,
                stops_turn,
                is_interactive,
            };
        };
        #[cfg(test)]
        {
            tokio::select! {
                biased;
                () = per_tool_cancel.cancelled() => {
                    warn!(tool_name, "cancelled during execution");
                    crate::core::tools::error_result("Operation cancelled")
                }
                result = tool.execute(effective_args, &tool_ctx) => {
                    match result {
                        Ok(r) => r,
                        Err(e) => crate::core::tools::error_result(e.to_string()),
                    }
                }
            }
        }
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
    let trace_id = match TraceId::new(format!("tool:{fingerprint}")) {
        Ok(id) => id,
        Err(error) => return crate::core::tools::error_result(error.to_string()),
    };
    let mut causal_context = CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("tool.read")
        .with_scope("tool.write")
        .with_scope("tool.invoke")
        .with_session_id(session_id.to_owned())
        .with_idempotency_key(idempotency_key);
    if let Some(workspace_id) = workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.to_owned());
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
    use crate::core::content::ToolResultContent;
    use crate::core::tools::{
        Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, text_result,
    };
    use crate::runtime::guardrails::rules::{GuardrailRule, RuleBase, pattern::PatternRule};
    use crate::runtime::guardrails::types::{RuleTier, Scope, Severity};
    use crate::runtime::hooks::errors::HookError;
    use crate::runtime::hooks::handler::HookHandler;
    use crate::runtime::hooks::registry::HookRegistry;
    use crate::runtime::hooks::types::{HookExecutionMode, HookResult as HookExecResult, HookType};
    use crate::tools::traits::TronTool;
    use async_trait::async_trait;
    use serde_json::{Map, json};
    use std::sync::OnceLock;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    fn test_execution_spec() -> &'static crate::core::profile::AgentExecutionSpec {
        static SPEC: OnceLock<crate::core::profile::AgentExecutionSpec> = OnceLock::new();
        SPEC.get_or_init(crate::core::profile::bundled_default_execution_spec)
    }

    macro_rules! tool_exec_ctx {
        ($registry:expr, $guardrails:expr, $hooks:expr, $emitter:expr, $cancel:expr) => {
            ToolExecutionContext {
                registry: $registry,
                guardrails: $guardrails,
                hooks: $hooks,
                emitter: $emitter,
                cancel: $cancel,
                subagent_depth: 0,
                subagent_max_depth: 0,
                workspace_id: None,
                process_manager: None,
                job_manager: None,
                output_buffer_registry: None,
                sequence_counter: None,
                provider_type: Provider::Anthropic,
                execution_spec: Some(test_execution_spec()),
                event_persister: None,
                turn: 0,
                tool_abort_registry: None,
                engine_host: None,
                run_id: None,
            }
        };
        ($registry:expr, $guardrails:expr, $hooks:expr, $emitter:expr, $cancel:expr, $provider:expr) => {
            ToolExecutionContext {
                registry: $registry,
                guardrails: $guardrails,
                hooks: $hooks,
                emitter: $emitter,
                cancel: $cancel,
                subagent_depth: 0,
                subagent_max_depth: 0,
                workspace_id: None,
                process_manager: None,
                job_manager: None,
                output_buffer_registry: None,
                sequence_counter: None,
                provider_type: $provider,
                execution_spec: Some(test_execution_spec()),
                event_persister: None,
                turn: 0,
                tool_abort_registry: None,
                engine_host: None,
                run_id: None,
            }
        };
    }

    // ── Test tool implementations ──

    struct EchoTool;

    #[async_trait]
    impl TronTool for EchoTool {
        fn name(&self) -> &'static str {
            "echo"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "echo".into(),
                description: "Echoes input".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, crate::tools::errors::ToolError> {
            let text = params
                .get("text")
                .and_then(|v| v.as_str())
                .unwrap_or("no text");
            Ok(text_result(text, false))
        }
    }

    struct StopTurnTool;

    #[async_trait]
    impl TronTool for StopTurnTool {
        fn name(&self) -> &'static str {
            "ask_user"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn stops_turn(&self) -> bool {
            true
        }
        fn is_interactive(&self) -> bool {
            true
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "ask_user".into(),
                description: "Ask user".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, crate::tools::errors::ToolError> {
            Ok(text_result("Asked user", false))
        }
    }

    struct ContinueHandler;

    #[async_trait]
    impl HookHandler for ContinueHandler {
        fn name(&self) -> &'static str {
            "test-continue"
        }

        fn hook_type(&self) -> HookType {
            HookType::PreToolUse
        }

        async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
            Ok(HookExecResult::continue_())
        }
    }

    struct BgHandler;

    #[async_trait]
    impl HookHandler for BgHandler {
        fn name(&self) -> &'static str {
            "test-bg"
        }

        fn hook_type(&self) -> HookType {
            HookType::PostToolUse
        }

        fn execution_mode(&self) -> HookExecutionMode {
            HookExecutionMode::Background
        }

        async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
            Ok(HookExecResult::continue_())
        }
    }

    struct SlowBackgroundHandler {
        completed: Arc<AtomicBool>,
    }

    #[async_trait]
    impl HookHandler for SlowBackgroundHandler {
        fn name(&self) -> &'static str {
            "test-slow"
        }

        fn hook_type(&self) -> HookType {
            HookType::PostToolUse
        }

        fn execution_mode(&self) -> HookExecutionMode {
            HookExecutionMode::Background
        }

        async fn handle(&self, _ctx: &HookContext) -> Result<HookExecResult, HookError> {
            tokio::time::sleep(std::time::Duration::from_secs(60)).await;
            self.completed.store(true, Ordering::SeqCst);
            Ok(HookExecResult::continue_())
        }
    }

    fn make_registry(tools: Vec<Arc<dyn TronTool>>) -> ToolRegistry {
        let mut registry = ToolRegistry::new();
        for tool in tools {
            registry.register(tool);
        }
        registry
    }

    fn make_tool_call(name: &str, args: Map<String, Value>) -> ToolCall {
        ToolCall::new("tc-1", name, args)
    }

    fn tool_result_text(result: &ToolExecutionResult) -> &str {
        let ToolResultBody::Blocks(blocks) = &result.result.content else {
            panic!("expected blocks result");
        };
        let ToolResultContent::Text { text } = &blocks[0] else {
            panic!("expected text block");
        };
        text
    }

    #[tokio::test]
    async fn successful_execution() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("hello"));
        let tc = make_tool_call("echo", args);

        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(!result.result.is_error.unwrap_or(false));
        assert!(!result.blocked_by_hook);
        assert!(!result.blocked_by_guardrail);
        assert!(!result.stops_turn);
        assert!(!result.is_interactive);
        assert!(result.duration_ms < 1000);
    }

    #[derive(Clone)]
    struct EngineEchoHandler {
        calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl crate::engine::InProcessFunctionHandler for EngineEchoHandler {
        async fn invoke(
            &self,
            invocation: crate::engine::Invocation,
        ) -> crate::engine::Result<Value> {
            let runtime_id = invocation.id.to_string();
            let execution =
                crate::tools::capability_runtime::take_runtime_tool_execution(&runtime_id)
                    .expect("runtime tool execution context");
            assert_eq!(execution.tool_name, "echo");
            assert_eq!(execution.context.session_id, "s1");
            assert_eq!(execution.context.tool_call_id, "tc-1");
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(serde_json::to_value(text_result("engine path", false)).unwrap())
        }
    }

    #[tokio::test]
    async fn tool_execution_routes_through_engine_and_replays_duplicate_model_call() {
        use crate::engine::{
            ActorId, AuthorityGrantId, AuthorityRequirement, EffectClass, FunctionDefinition,
            FunctionId, IdempotencyContract, Provenance, RiskLevel, VisibilityScope,
            WorkerDefinition, WorkerId, WorkerKind,
        };

        let host = EngineHostHandle::new_in_memory().unwrap();
        let worker_id = WorkerId::new("tool").unwrap();
        host.register_worker_for_setup(
            WorkerDefinition::new(
                worker_id.clone(),
                WorkerKind::InProcess,
                ActorId::new("system").unwrap(),
                AuthorityGrantId::new("test").unwrap(),
            )
            .with_namespace_claim("tool"),
            false,
        )
        .unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let mut function = FunctionDefinition::new(
            FunctionId::new("tool::echo").unwrap(),
            worker_id,
            "test engine tool",
            VisibilityScope::System,
            EffectClass::IdempotentWrite,
        )
        .with_risk(RiskLevel::Medium)
        .with_required_authority(AuthorityRequirement::scope("tool.write"))
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_provenance(Provenance::system())
        .with_request_schema(json!({"type": "object", "additionalProperties": true}))
        .with_response_schema(json!({"type": "object", "additionalProperties": true}));
        function.metadata = json!({
            "modelToolName": "echo",
            "toolOrder": 0,
            "stopsTurn": false,
            "isInteractive": false,
        });
        host.register_function_for_setup(
            function,
            Some(Arc::new(EngineEchoHandler {
                calls: calls.clone(),
            })),
            false,
        )
        .unwrap();

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;
        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("hello"));
        let tc = make_tool_call("echo", args);
        let mut ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        ctx.engine_host = Some(&host);
        ctx.run_id = Some("run-1");
        ctx.turn = 7;

        let first = execute_tool(&tc, "s1", "/tmp", &ctx).await;
        let second = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert_eq!(tool_result_text(&first), "engine path");
        assert_eq!(tool_result_text(&second), "engine path");
    }

    #[tokio::test]
    async fn tool_not_found() {
        let registry = ToolRegistry::new();
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("nonexistent", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(result.result.is_error.unwrap_or(false));
        let ToolResultBody::Blocks(blocks) = &result.result.content else {
            panic!("Expected blocks result");
        };
        let ToolResultContent::Text { text } = &blocks[0] else {
            panic!("Expected text block");
        };
        assert!(text.contains("not found"));
    }

    #[tokio::test]
    async fn guardrail_blocks() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();

        // Set up guardrails that block "echo" with dangerous args
        let mut engine =
            GuardrailEngine::new(crate::runtime::guardrails::GuardrailEngineOptions::default());
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test-block".into(),
                name: "Block rm".into(),
                description: "Block rm commands".into(),
                severity: Severity::Block,
                scope: Scope::Tool,
                tier: RuleTier::Custom,
                tools: vec!["echo".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "text".into(),
            patterns: vec![regex::Regex::new("rm -rf").unwrap()],
        }));

        let guardrails = Some(Arc::new(parking_lot::Mutex::new(engine)));
        let no_hooks = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("rm -rf /"));
        let tc = make_tool_call("echo", args);

        let ctx = tool_exec_ctx!(&registry, &guardrails, &no_hooks, &emitter, &cancel);
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(result.result.is_error.unwrap_or(false));
        assert!(result.blocked_by_guardrail);
    }

    #[tokio::test]
    async fn stop_turn_tool_flags() {
        let registry = make_registry(vec![Arc::new(StopTurnTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("ask_user", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(!result.result.is_error.unwrap_or(false));
        assert!(result.stops_turn);
        assert!(result.is_interactive);
    }

    #[tokio::test]
    async fn cancelled_before_execution() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        cancel.cancel();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("echo", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn emits_start_and_end_events() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let _ = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        let mut saw_start = false;
        let mut saw_end = false;
        while let Ok(event) = rx.try_recv() {
            match event {
                TronEvent::ToolExecutionStart { tool_name, .. } if tool_name == "echo" => {
                    saw_start = true;
                }
                TronEvent::ToolExecutionEnd { tool_name, .. } if tool_name == "echo" => {
                    saw_end = true;
                }
                _ => {}
            }
        }
        assert!(saw_start);
        assert!(saw_end);
    }

    #[tokio::test]
    async fn pre_tool_use_hook_emits_triggered_and_completed() {
        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(ContinueHandler));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();
        let no_guardrails = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let hooks = Some(hook_engine);
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &hooks, &emitter, &cancel);
        let _ = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        let mut saw_triggered = false;
        let mut saw_completed = false;
        while let Ok(event) = rx.try_recv() {
            match &event {
                TronEvent::HookTriggered { hook_event, .. } if hook_event == "PreToolUse" => {
                    saw_triggered = true;
                }
                TronEvent::HookCompleted { hook_event, .. } if hook_event == "PreToolUse" => {
                    saw_completed = true;
                }
                _ => {}
            }
        }
        assert!(saw_triggered, "should emit HookTriggered for PreToolUse");
        assert!(saw_completed, "should emit HookCompleted for PreToolUse");
    }

    #[tokio::test]
    async fn post_tool_use_hook_emits_triggered() {
        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(BgHandler));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();
        let no_guardrails = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let hooks = Some(hook_engine);
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &hooks, &emitter, &cancel);
        let _ = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        // Give background task a moment to complete
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let mut saw_triggered = false;
        let mut saw_completed = false;
        while let Ok(event) = rx.try_recv() {
            match &event {
                TronEvent::HookTriggered { hook_event, .. } if hook_event == "PostToolUse" => {
                    saw_triggered = true;
                }
                TronEvent::HookCompleted { hook_event, .. } if hook_event == "PostToolUse" => {
                    saw_completed = true;
                }
                _ => {}
            }
        }
        assert!(saw_triggered, "should emit HookTriggered for PostToolUse");
        assert!(saw_completed, "should emit HookCompleted for PostToolUse");
    }

    #[tokio::test]
    async fn post_tool_use_hook_timeout() {
        // Track whether the handler completed (it shouldn't — timeout fires first)
        let handler_completed = Arc::new(AtomicBool::new(false));

        tokio::time::pause();

        let mut hook_registry = HookRegistry::new();
        hook_registry.register(Arc::new(SlowBackgroundHandler {
            completed: Arc::clone(&handler_completed),
        }));
        let hook_engine = Arc::new(HookEngine::new(hook_registry));

        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;

        let mut args = Map::new();
        let _ = args.insert("text".into(), json!("test"));
        let tc = make_tool_call("echo", args);

        let hooks = Some(hook_engine);
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &hooks, &emitter, &cancel);
        let _ = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        // Let the spawned task start and register its timers
        tokio::task::yield_now().await;

        // Advance past the 30s timeout (but not past 60s handler sleep)
        tokio::time::advance(std::time::Duration::from_secs(31)).await;
        tokio::task::yield_now().await;

        // The handler should NOT have completed (timeout fired first)
        assert!(
            !handler_completed.load(Ordering::SeqCst),
            "handler should not have completed — timeout should have fired"
        );
    }

    #[tokio::test]
    async fn multiple_sequential_tools() {
        let registry = make_registry(vec![Arc::new(EchoTool), Arc::new(StopTurnTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc1 = make_tool_call("echo", {
            let mut m = Map::new();
            let _ = m.insert("text".into(), json!("a"));
            m
        });
        let tc2 = make_tool_call("ask_user", Map::new());

        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);
        let r1 = execute_tool(&tc1, "s1", "/tmp", &ctx).await;
        let r2 = execute_tool(&tc2, "s1", "/tmp", &ctx).await;

        assert!(!r1.result.is_error.unwrap_or(false));
        assert!(!r1.stops_turn);
        assert!(!r2.result.is_error.unwrap_or(false));
        assert!(r2.stops_turn);
    }

    #[tokio::test]
    async fn guardrail_lock_always_succeeds() {
        let engine =
            GuardrailEngine::new(crate::runtime::guardrails::GuardrailEngineOptions::default());
        let guardrails = Arc::new(parking_lot::Mutex::new(engine));
        // parking_lot::Mutex::lock() always succeeds (no Result, no poison)
        let _guard = guardrails.lock();
    }

    // ── SlowTool: sleeps 60s to test mid-execution cancellation ──

    struct SlowTool;

    #[async_trait]
    impl TronTool for SlowTool {
        fn name(&self) -> &'static str {
            "slow"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "slow".into(),
                description: "Sleeps for 60s".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, crate::tools::errors::ToolError> {
            tokio::time::sleep(Duration::from_secs(60)).await;
            Ok(text_result("completed", false))
        }
    }

    #[tokio::test]
    async fn cancelled_during_execution() {
        let registry = make_registry(vec![Arc::new(SlowTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("slow", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);

        // Cancel after 100ms — tool should NOT run for 60s
        let cancel2 = cancel.clone();
        drop(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            cancel2.cancel();
        }));

        let start = Instant::now();
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;
        let elapsed = start.elapsed();

        assert!(result.result.is_error.unwrap_or(false));
        assert!(
            elapsed < Duration::from_secs(2),
            "should cancel quickly, took {elapsed:?}"
        );
    }

    #[tokio::test]
    async fn cancelled_during_execution_emits_start_and_end() {
        let registry = make_registry(vec![Arc::new(SlowTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("slow", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);

        let cancel2 = cancel.clone();
        drop(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            cancel2.cancel();
        }));

        let _ = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        let mut saw_start = false;
        let mut saw_end = false;
        while let Ok(event) = rx.try_recv() {
            match event {
                TronEvent::ToolExecutionStart { tool_name, .. } if tool_name == "slow" => {
                    saw_start = true;
                }
                TronEvent::ToolExecutionEnd { tool_name, .. } if tool_name == "slow" => {
                    saw_end = true;
                }
                _ => {}
            }
        }
        assert!(saw_start, "should emit ToolExecutionStart");
        assert!(saw_end, "should emit ToolExecutionEnd");
    }

    #[tokio::test]
    async fn cancelled_during_execution_result_is_error() {
        let registry = make_registry(vec![Arc::new(SlowTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("slow", Map::new());
        let ctx = tool_exec_ctx!(&registry, &no_guardrails, &no_hooks, &emitter, &cancel);

        let cancel2 = cancel.clone();
        drop(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            cancel2.cancel();
        }));

        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(result.result.is_error.unwrap_or(false));
        let ToolResultBody::Blocks(blocks) = &result.result.content else {
            panic!("Expected blocks result");
        };
        let ToolResultContent::Text { text } = &blocks[0] else {
            panic!("Expected text block");
        };
        assert!(
            text.to_lowercase().contains("cancelled"),
            "error should mention cancellation, got: {text}"
        );
    }

    // ── Local-model tool allow-list ──

    /// Stand-in for a cloud-only tool (e.g. SpawnSubagent) not on the local
    /// allow-list. Uses a name that is definitely not in the profile's local
    /// tool policy.
    struct CloudOnlyTool;

    #[async_trait]
    impl TronTool for CloudOnlyTool {
        fn name(&self) -> &'static str {
            "SpawnSubagent"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "SpawnSubagent".into(),
                description: "Cloud-only".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, crate::tools::errors::ToolError> {
            Ok(text_result("executed", false))
        }
    }

    /// A tool whose name matches an allow-listed local name. Used to verify
    /// local sessions can still execute permitted tools.
    struct ReadTool;

    #[async_trait]
    impl TronTool for ReadTool {
        fn name(&self) -> &'static str {
            "Read"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "Read".into(),
                description: "Read a file".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _params: Value,
            _ctx: &ToolContext,
        ) -> Result<TronToolResult, crate::tools::errors::ToolError> {
            Ok(text_result("read ok", false))
        }
    }

    #[tokio::test]
    async fn local_model_blocks_off_list_tool() {
        let registry = make_registry(vec![Arc::new(CloudOnlyTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("SpawnSubagent", Map::new());
        let ctx = tool_exec_ctx!(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            Provider::Ollama
        );
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(result.result.is_error.unwrap_or(false));
        let ToolResultBody::Blocks(blocks) = &result.result.content else {
            panic!("expected blocks result");
        };
        let ToolResultContent::Text { text } = &blocks[0] else {
            panic!("expected text block");
        };
        assert!(
            text.contains("not available for local models"),
            "got: {text}"
        );
    }

    #[tokio::test]
    async fn local_model_allows_listed_tool() {
        let registry = make_registry(vec![Arc::new(ReadTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("Read", Map::new());
        let ctx = tool_exec_ctx!(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            Provider::Ollama
        );
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(!result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn cloud_model_executes_any_registered_tool() {
        // Regression guard: cloud path must not be affected by the local allow-list.
        let registry = make_registry(vec![Arc::new(CloudOnlyTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;

        let tc = make_tool_call("SpawnSubagent", Map::new());
        let ctx = tool_exec_ctx!(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            Provider::Anthropic
        );
        let result = execute_tool(&tc, "s1", "/tmp", &ctx).await;

        assert!(!result.result.is_error.unwrap_or(false));
    }

    #[tokio::test]
    async fn guardrail_evaluates_after_lock() {
        let mut engine =
            GuardrailEngine::new(crate::runtime::guardrails::GuardrailEngineOptions::default());
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test".into(),
                name: "Test".into(),
                description: "Test".into(),
                severity: Severity::Block,
                scope: Scope::Tool,
                tier: RuleTier::Custom,
                tools: vec!["bash".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("rm").unwrap()],
        }));

        let guardrails = Arc::new(parking_lot::Mutex::new(engine));
        let guard = guardrails.lock();
        let eval_ctx = EvaluationContext {
            tool_name: "bash".into(),
            tool_arguments: json!({"command": "rm -rf /"}),
            session_id: None,
            tool_call_id: None,
        };
        // Can't call evaluate on immutable guard — drop and re-lock as mutable
        drop(guard);
        let mut guard = guardrails.lock();
        let eval = guard.evaluate(&eval_ctx);
        assert!(eval.blocked);
    }

    // ── Per-tool abort registry tests (agent.abortTool backing) ──

    fn tool_exec_ctx_with_registry<'a>(
        registry: &'a ToolRegistry,
        guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
        hooks: &'a Option<Arc<HookEngine>>,
        emitter: &'a Arc<EventEmitter>,
        cancel: &'a CancellationToken,
        abort_registry: &'a Arc<ToolAbortRegistry>,
    ) -> ToolExecutionContext<'a> {
        ToolExecutionContext {
            registry,
            guardrails,
            hooks,
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
            execution_spec: Some(test_execution_spec()),
            event_persister: None,
            turn: 0,
            tool_abort_registry: Some(abort_registry),
            engine_host: None,
            run_id: None,
        }
    }

    #[tokio::test]
    async fn abort_tool_cancels_only_target_leaves_siblings_running() {
        let registry = make_registry(vec![Arc::new(SlowTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;
        let abort_registry = Arc::new(ToolAbortRegistry::new());

        let tc_target = ToolCall::new("target-call", "slow", Map::new());
        let tc_sibling = ToolCall::new("sibling-call", "slow", Map::new());

        let ctx_a = tool_exec_ctx_with_registry(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            &abort_registry,
        );
        let ctx_b = tool_exec_ctx_with_registry(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            &abort_registry,
        );

        let abort_registry_clone = abort_registry.clone();
        let aborter = async {
            for _ in 0..100 {
                if abort_registry_clone.len() >= 2 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert_eq!(
                abort_registry_clone.len(),
                2,
                "both tools should be registered before abort is called"
            );
            assert!(abort_registry_clone.abort("sess-1", "target-call"));
        };

        let target_future = execute_tool(&tc_target, "sess-1", "/tmp", &ctx_a);
        // Sibling runs the 60s SlowTool — wrap it in a short timeout so the
        // test asserts "still running" by observing the timeout fires. Dropping
        // the timeout future cancels the inner future (good test cleanup).
        let sibling_future = tokio::time::timeout(
            Duration::from_millis(800),
            execute_tool(&tc_sibling, "sess-1", "/tmp", &ctx_b),
        );

        let (target_result, sibling_timeout_result, ()) =
            tokio::join!(target_future, sibling_future, aborter);

        assert!(
            target_result.result.is_error.unwrap_or(false),
            "aborted target returns an error result"
        );
        assert!(
            sibling_timeout_result.is_err(),
            "sibling must still be running when the 800ms timeout fires — per-tool abort must not propagate to siblings"
        );
    }

    #[tokio::test]
    async fn abort_tool_unregisters_after_successful_completion() {
        let registry = make_registry(vec![Arc::new(EchoTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;
        let abort_registry = Arc::new(ToolAbortRegistry::new());

        let mut args = Map::new();
        args.insert("text".into(), Value::String("hi".into()));
        let tc = ToolCall::new("done-call", "echo", args);

        let ctx = tool_exec_ctx_with_registry(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            &abort_registry,
        );
        let result = execute_tool(&tc, "sess-1", "/tmp", &ctx).await;
        assert!(!result.result.is_error.unwrap_or(false));
        assert!(
            abort_registry.is_empty(),
            "RAII guard must unregister the tool on normal completion"
        );
    }

    #[tokio::test]
    async fn parent_cancel_still_cancels_tool_when_registry_present() {
        let registry = make_registry(vec![Arc::new(SlowTool)]);
        let emitter = Arc::new(EventEmitter::new());
        let cancel = CancellationToken::new();
        let no_guardrails = None;
        let no_hooks = None;
        let abort_registry = Arc::new(ToolAbortRegistry::new());

        let tc = make_tool_call("slow", Map::new());
        let ctx = tool_exec_ctx_with_registry(
            &registry,
            &no_guardrails,
            &no_hooks,
            &emitter,
            &cancel,
            &abort_registry,
        );

        let cancel2 = cancel.clone();
        drop(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(100)).await;
            cancel2.cancel();
        }));

        let start = Instant::now();
        let result = execute_tool(&tc, "sess-1", "/tmp", &ctx).await;
        let elapsed = start.elapsed();

        assert!(result.result.is_error.unwrap_or(false));
        assert!(elapsed < Duration::from_secs(2));
        assert!(
            abort_registry.is_empty(),
            "guard cleans up even on parent cancel"
        );
    }

    #[tokio::test]
    async fn abort_unknown_tool_call_is_noop() {
        let abort_registry = Arc::new(ToolAbortRegistry::new());
        assert!(!abort_registry.abort("sess-x", "does-not-exist"));
    }
}
