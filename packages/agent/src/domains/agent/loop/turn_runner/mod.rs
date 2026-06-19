//! Turn runner — orchestrates a single turn: context → stream → capabilities → events.
//!
//! Capability result content is the only provider-portable channel back into
//! the model. Engine/UI/audit metadata stays in `details`, but model-facing
//! `execute` observations are projected into result text here so every provider
//! can reason about direct primitive results without gaining a second
//! capability API.

mod capability_invocations;
mod persistence;
mod result;
mod turn_context;

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::Instant;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::model::responder::{ModelResponder, ModelResponseRequest};
use crate::shared::protocol::events::{BaseEvent, turn_failed_event};
use crate::shared::server::failure::{
    ASSISTANT_PERSIST_FAILED, ENGINE_TOOL_SURFACE_FAILED, FailureCategory, FailureEnvelope,
    FailureOrigin, JOURNAL_CREATE_FAILED, MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED,
};

use metrics::{counter, histogram};
use tracing::{error, info, instrument, trace, warn};

use self::capability_invocations::CapabilityInvocationPhaseParams;
use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload,
    build_interrupted_message_payload, build_token_record_json, emit_response_complete,
    emit_turn_end, emit_turn_start, persist_completed_assistant_message,
    persist_interrupted_message, persist_model_provider_request_audit,
};
use self::result::determine_turn_stop_reason;
use self::turn_context::{build_turn_context, resolve_provider_primitive_surface};
use crate::domains::agent::r#loop::compaction_handler::CompactionHandler;
use crate::domains::agent::r#loop::errors::StopReason;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::stream_processor;
use crate::domains::agent::r#loop::types::{RunContext, TurnResult};

fn run_base(session_id: &str, run_context: &RunContext) -> BaseEvent {
    BaseEvent::now(session_id).with_trace_context(
        run_context
            .engine_trace_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
        run_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
    )
}

fn emit_turn_failure(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    turn: u32,
    run_context: &RunContext,
    sequence_counter: Option<&AtomicI64>,
    failure: &FailureEnvelope,
    partial_content: Option<String>,
) {
    let event = turn_failed_event(
        run_base(session_id, run_context),
        turn,
        failure,
        partial_content,
    );
    if let Some(counter) = sequence_counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}

/// Parameters for a single turn of the agent loop.
pub struct TurnParams<'a> {
    /// Current turn number (1-indexed).
    pub turn: u32,
    /// Context manager owning messages, agent state summaries, and token tracking.
    pub context_manager: &'a mut ContextManager,
    /// Model responder for streaming.
    pub responder: &'a Arc<dyn ModelResponder>,
    /// Compaction handler for pre-turn context checks.
    pub compaction: &'a CompactionHandler,
    /// Session identifier.
    pub session_id: &'a str,
    /// Event emitter for broadcasting agent lifecycle events.
    pub emitter: &'a Arc<EventEmitter>,
    /// Cancellation token for aborting the turn.
    pub cancel: &'a tokio_util::sync::CancellationToken,
    /// Run-scoped context for reasoning level, trace ids, and agent-owned state.
    pub run_context: &'a RunContext,
    /// Optional event persister for inline event storage.
    pub persister: Option<&'a EventPersister>,
    /// Previous turn's context window token count (for delta tracking).
    pub previous_context_baseline: u64,
    /// Optional retry configuration for provider stream retries.
    pub retry_config: Option<&'a crate::shared::foundation::retry::RetryConfig>,
    /// Workspace ID for scoping capability context (e.g. memory recall).
    pub workspace_id: Option<&'a str>,
    /// Server origin (e.g. `"localhost:9847"`) for system prompt.
    pub server_origin: Option<&'a str>,
    /// Optional per-session sequence counter for monotonic event ordering.
    pub sequence_counter: Option<&'a AtomicI64>,
    /// Optional per-invocation abort registry. Threaded into `CapabilityInvocationExecutionContext`
    /// so each in-flight capability invocation registers a child `CancellationToken` that
    /// `agent.abortCapabilityInvocation` can cancel independently of the turn token.
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    /// Optional engine host for engine-owned capability invocation.
    pub engine_host: Option<&'a crate::engine::EngineHostHandle>,
}

/// Execute a single turn of the agent loop.
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(session_id, turn, model = %params.responder.model()))]
pub async fn execute_turn(params: TurnParams<'_>) -> TurnResult {
    let TurnParams {
        turn,
        context_manager,
        responder,
        compaction,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        previous_context_baseline,
        retry_config,
        workspace_id,
        server_origin,
        sequence_counter,
        invocation_abort_registry,
        engine_host,
    } = params;
    let turn_start = Instant::now();
    let run_id = run_context.run_id.as_deref().unwrap_or("none");
    let trace_id = run_context
        .engine_trace_id
        .as_ref()
        .map(|id| id.as_str())
        .unwrap_or("none");
    let parent_invocation_id = run_context
        .parent_invocation_id
        .as_ref()
        .map(|id| id.as_str())
        .unwrap_or("none");
    info!(
        component = "agent.turn",
        agent_event = "turn_entered",
        session_id,
        run_id,
        trace_id,
        parent_invocation_id,
        turn,
        model = %responder.model(),
        "agent turn entered"
    );

    // H15 INVARIANT: every turn-entry path must advance the context
    // manager's generation counter before any snapshot readers run, then
    // refresh volatile tokens via set_volatile_tokens (called inside
    // build_turn_context below). If a future refactor introduces a new
    // turn-entry path that skips set_volatile_tokens, the debug_assert
    // inside `get_snapshot` / `get_detailed_snapshot` will fire.
    context_manager.begin_turn();

    // 1. Check context capacity (compact if needed)
    match compaction
        .check_and_compact(context_manager, session_id, emitter, sequence_counter)
        .await
    {
        Err(e) => {
            warn!(
                component = "agent.turn",
                agent_event = "pre_turn_compaction_failed",
                session_id,
                run_id,
                trace_id,
                turn,
                error = %e,
                "pre-turn compaction failed"
            );
            counter!("compaction_total", "status" => "pre_turn_error").increment(1);
            return TurnResult {
                success: false,
                error: Some(format!("Compaction error: {e}")),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
        Ok(compacted) => {
            trace!(
                component = "agent.turn",
                agent_event = "pre_turn_compaction_checked",
                session_id,
                run_id,
                trace_id,
                turn,
                compacted,
                "pre-turn compaction checked"
            );
        }
    }

    // 2. Emit TurnStart and persist (TS persists stream.turn_start events)
    emit_turn_start(
        emitter,
        persister,
        session_id,
        turn,
        sequence_counter,
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await;
    info!(
        component = "agent.turn",
        agent_event = "turn_started_event_recorded",
        session_id,
        run_id,
        trace_id,
        parent_invocation_id,
        turn,
        "turn start persisted and broadcast"
    );

    let primitive_surface =
        match resolve_provider_primitive_surface(engine_host, session_id, workspace_id).await {
            Ok(capabilities) => capabilities,
            Err(error) => {
                let error_msg =
                    format!("failed to resolve live engine capability surface: {error}");
                error!(session_id, turn, error = %error_msg);
                let failure = FailureEnvelope::new(
                    ENGINE_TOOL_SURFACE_FAILED,
                    FailureCategory::Engine,
                    error_msg.clone(),
                    true,
                    true,
                    FailureOrigin::Engine,
                );
                emit_turn_failure(
                    emitter,
                    session_id,
                    turn,
                    run_context,
                    sequence_counter,
                    &failure,
                    None,
                );
                return TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(StopReason::Error),
                    ..Default::default()
                };
            }
        };
    info!(
        component = "agent.turn",
        agent_event = "primitive_surface_resolved",
        session_id,
        run_id,
        trace_id,
        turn,
        capability_count = primitive_surface.capabilities.len(),
        turn_stopping_capability_count = primitive_surface.turn_stopping_capabilities.len(),
        "provider primitive surface resolved"
    );
    // 3. Build context (base from CM, external fields from RunContext/params)
    let context = build_turn_context(
        context_manager,
        run_context,
        server_origin,
        primitive_surface.capabilities.clone(),
    );

    // 4. Build and durably persist the provider request audit before the model
    // stream opens. Provider selection, provider-native options, retry
    // wrapping, and provider error mapping stay inside `domains::model`.
    let model_request = ModelResponseRequest {
        context,
        session_id: session_id.to_owned(),
        reasoning_level: run_context.reasoning_level.clone(),
        cancel: cancel.clone(),
        retry_config: retry_config.cloned(),
    };
    let model_request_audit = match responder.request_audit(&model_request) {
        Ok(audit) => audit,
        Err(error) => {
            let error_msg = error.to_string();
            let failure = error.failure().clone();
            let category = failure.category.as_str().to_owned();
            warn!(
                model = %responder.model(),
                status = %category,
                error = %error,
                "model provider request audit error"
            );
            emit_turn_failure(
                emitter,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                None,
            );
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };
    trace!(
        component = "agent.provider",
        agent_event = "model_provider_request_audit_built",
        session_id,
        run_id,
        trace_id,
        turn,
        model = %responder.model(),
        "model provider request audit built"
    );
    if let Err(error) = persist_model_provider_request_audit(
        persister,
        session_id,
        &model_request_audit,
        sequence_counter,
    )
    .await
    {
        let error_msg = format!("failed to persist model provider request audit: {error}");
        error!(session_id, turn, error = %error_msg);
        let failure = FailureEnvelope::new(
            MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED,
            FailureCategory::Persistence,
            error_msg.clone(),
            false,
            false,
            FailureOrigin::AgentRuntime,
        );
        emit_turn_failure(
            emitter,
            session_id,
            turn,
            run_context,
            sequence_counter,
            &failure,
            None,
        );
        return TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
    }
    info!(
        component = "agent.provider",
        agent_event = "model_provider_request_audit_persisted",
        session_id,
        run_id,
        trace_id,
        turn,
        model = %responder.model(),
        "model provider request audit persisted"
    );

    info!(
        component = "agent.provider",
        agent_event = "model_response_requested",
        session_id,
        run_id,
        trace_id,
        turn,
        model = %responder.model(),
        "model response requested"
    );
    let response = match responder.respond(model_request).await {
        Ok(response) => response,
        Err(error) => {
            let error_msg = error.to_string();
            let failure = error.failure().clone();
            let category = failure.category.as_str().to_owned();
            warn!(
                model = %responder.model(),
                status = %category,
                error = %error,
                "model response error"
            );

            emit_turn_failure(
                emitter,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                None,
            );

            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };
    let response_info = response.info;
    let provider_name: &'static str = response_info.provider_name;
    let provider_type = response_info.provider_type;
    let model_name = response_info.model;
    let stream = response.stream;
    info!(
        component = "agent.provider",
        agent_event = "model_stream_opened",
        session_id,
        run_id,
        trace_id,
        turn,
        provider = provider_name,
        provider_type = %provider_type.as_str(),
        model = %model_name,
        "model response stream opened"
    );

    // 5. Create streaming journal for crash recovery.
    //
    // Failure is a turn error, not a warning. Without the journal, a
    // mid-stream crash loses the partial assistant message and session
    // reconstruction on restart is broken for that turn. Silently
    // continuing masks the real problem (disk full, bad perms, missing
    // directory) and defers the damage to the next crash — by which
    // point the operator has no warning.
    let mut journal = match StreamingJournal::create(session_id, turn) {
        Ok(j) => Some(j),
        Err(e) => {
            let error_msg = format!(
                "failed to create streaming journal for crash recovery: {e}. \
                 Check that ~/.tron/internal/database/journals/ is writable."
            );
            error!(session_id, turn, error = %error_msg);
            let failure = FailureEnvelope::new(
                JOURNAL_CREATE_FAILED,
                FailureCategory::Persistence,
                error_msg.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            );
            emit_turn_failure(
                emitter,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                None,
            );
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };
    trace!(
        component = "agent.stream",
        agent_event = "streaming_journal_created",
        session_id,
        run_id,
        trace_id,
        turn,
        "streaming journal created"
    );

    // 6. Process stream (drain after turn-stopping capabilities to capture token usage cleanly)
    let stream_result = match stream_processor::process_stream_with_trace(
        stream,
        session_id,
        emitter,
        cancel,
        &primitive_surface.turn_stopping_capabilities,
        sequence_counter,
        journal.as_mut(),
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            let error_msg = e.to_string();
            error!(session_id, turn, error = %error_msg, "stream failed");
            let failure = e.to_failure();
            emit_turn_failure(
                emitter,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                None,
            );
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };
    info!(
        component = "agent.stream",
        agent_event = "model_stream_completed",
        session_id,
        run_id,
        trace_id,
        turn,
        provider = provider_name,
        model = %model_name,
        stop_reason = %stream_result.stop_reason,
        capability_invocation_count = stream_result.capability_invocations.len(),
        has_token_usage = stream_result.token_usage.is_some(),
        ttft_ms = stream_result.ttft_ms.unwrap_or_default(),
        interrupted = stream_result.interrupted,
        "model response stream completed"
    );

    // Record time-to-first-token if available
    if let Some(ttft) = stream_result.ttft_ms {
        histogram!("provider_ttft_seconds", "provider" => provider_name).record({
            #[allow(clippy::cast_precision_loss)]
            let secs = ttft as f64 / 1000.0;
            secs
        });
    }

    // Record LLM token counts
    if let Some(ref usage) = stream_result.token_usage {
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "input")
            .increment(usage.input_tokens);
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "output")
            .increment(usage.output_tokens);
    }

    if stream_result.interrupted {
        persist_interrupted_message(
            persister,
            session_id,
            build_interrupted_message_payload(
                &stream_result.message,
                stream_result.token_usage.as_ref(),
                session_id,
                turn,
                &model_name,
                provider_type,
                previous_context_baseline,
            ),
            sequence_counter,
        )
        .await;

        // Finalize journal — interrupted message was persisted successfully
        if let Some(j) = journal.take() {
            if let Err(e) = j.finalize_and_delete() {
                warn!(session_id, turn, error = %e, "failed to finalize streaming journal after interruption");
            }
        }

        return TurnResult {
            success: true,
            interrupted: true,
            partial_content: stream_result.partial_content,
            stop_reason: Some(StopReason::Interrupted),
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    // 8. Build token record + cost BEFORE ResponseComplete (iOS attaches stats from this)
    let (token_record_json, cost) = build_token_record_json(
        stream_result.token_usage.as_ref(),
        provider_type,
        session_id,
        turn,
        previous_context_baseline,
        &model_name,
    );

    // INVARIANT: persist message.assistant BEFORE broadcasting
    // ResponseComplete. If persist fails we cannot emit because iOS would
    // see "response complete" for a message that is missing from the DB
    // on reconnect. Fail the turn with an actionable error instead.
    let has_thinking = {
        let content_has_thinking = stream_result.message.content.iter().any(|c| {
            matches!(
                c,
                crate::shared::protocol::content::AssistantContent::Thinking { .. }
            )
        });
        content_has_thinking
    };

    let assistant_payload = build_completed_assistant_payload(
        &stream_result,
        turn,
        &model_name,
        turn_start.elapsed().as_millis() as u64,
        has_thinking,
        provider_type,
        token_record_json.as_ref(),
        cost,
    );

    if let Err(error) = persist_completed_assistant_message(
        persister,
        session_id,
        assistant_payload,
        sequence_counter,
    )
    .await
    {
        let error_msg = format!("failed to persist assistant message: {error}");
        error!(session_id, turn, error = %error_msg);
        let failure = FailureEnvelope::new(
            ASSISTANT_PERSIST_FAILED,
            FailureCategory::Persistence,
            error_msg.clone(),
            false,
            false,
            FailureOrigin::AgentRuntime,
        );
        emit_turn_failure(
            emitter,
            session_id,
            turn,
            run_context,
            sequence_counter,
            &failure,
            None,
        );
        return TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
    }
    info!(
        component = "agent.turn",
        agent_event = "assistant_message_persisted",
        session_id,
        run_id,
        trace_id,
        turn,
        model = %model_name,
        has_thinking,
        has_token_usage = stream_result.token_usage.is_some(),
        "assistant message persisted"
    );

    // Persist succeeded — safe to commit the assistant turn to local context
    // and tell iOS the response is complete.
    let _ = add_assistant_message_to_context(context_manager, &stream_result);
    if let Some(context_window_tokens) = token_record_json
        .as_ref()
        .and_then(|r| r["computed"]["contextWindowTokens"].as_u64())
    {
        context_manager.set_api_context_tokens(context_window_tokens);
    }
    emit_response_complete(
        emitter,
        session_id,
        turn,
        &stream_result,
        token_record_json.clone(),
        &model_name,
        sequence_counter,
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    );

    // Finalize journal — assistant message was persisted successfully
    if let Some(j) = journal.take() {
        if let Err(e) = j.finalize_and_delete() {
            warn!(session_id, turn, error = %e, "failed to finalize streaming journal");
        }
    }

    let invocation_phase = capability_invocations::execute_capability_invocation_phase(
        CapabilityInvocationPhaseParams {
            turn,
            stream_result: &stream_result,
            context_manager,
            primitive_surface: &primitive_surface,
            session_id,
            emitter,
            cancel,
            workspace_id,
            persister,
            sequence_counter,
            invocation_abort_registry,
            engine_host,
            run_id: run_context.run_id.as_deref(),
            provider_type: provider_name,
            trace_id: run_context.engine_trace_id.as_ref(),
            parent_invocation_id: run_context.parent_invocation_id.as_ref(),
        },
    )
    .await;

    // 10. Emit TurnEnd
    let duration = turn_start.elapsed().as_millis() as u64;
    emit_turn_end(
        emitter,
        persister,
        session_id,
        turn,
        duration,
        &stream_result,
        token_record_json.clone(),
        cost,
        context_manager.get_context_limit(),
        &model_name,
        sequence_counter,
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await;

    info!(
        component = "agent.turn",
        agent_event = "turn_completed",
        session_id,
        run_id,
        trace_id,
        parent_invocation_id,
        turn,
        duration_ms = duration,
        model = %model_name,
        stop_reason = %stream_result.stop_reason,
        capabilities = invocation_phase.capability_invocations_executed,
        has_thinking,
        "turn completed"
    );

    // Record turn metrics
    counter!("agent_turns_total", "model" => model_name.clone()).increment(1);
    histogram!("agent_turn_duration_seconds", "model" => model_name.clone())
        .record(turn_start.elapsed().as_secs_f64());

    // Determine stop reason for this turn
    let stop_reason = determine_turn_stop_reason(
        invocation_phase.stop_turn_requested,
        stream_result.capability_invocations.len(),
        &stream_result.stop_reason,
    );

    let context_window_tokens = token_record_json
        .as_ref()
        .and_then(|r| r["computed"]["contextWindowTokens"].as_u64());

    TurnResult {
        success: true,
        capability_invocations_executed: invocation_phase.capability_invocations_executed,
        token_usage: stream_result.token_usage,
        stop_reason,
        stop_turn_requested: invocation_phase.stop_turn_requested,
        model: Some(model_name),
        latency_ms: duration,
        has_thinking,
        llm_stop_reason: Some(stream_result.stop_reason.clone()),
        context_window_tokens,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests;
