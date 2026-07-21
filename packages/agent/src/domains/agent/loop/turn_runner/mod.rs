//! Turn runner — orchestrates a single turn: context → stream → capabilities → events.
//!
//! Capability result content is the only provider-portable channel back into
//! the model. Engine/UI/audit metadata stays in `details`, but model-facing
//! `execute` observations are projected into result text by
//! `capability_invocations::projection` so every provider can reason about
//! direct primitive results without gaining a second capability API. Every
//! provider turn resolves its tool surface from a bounded evolving intent query
//! containing the current user request, visible assistant plan, tool names and
//! arguments, and text results; binary data and hidden thinking are excluded.

mod capability_invocations;
mod failure;
mod params;
mod persistence;
mod turn_context;

use std::sync::Arc;
use std::time::Instant;

use crate::domains::model::responder::ModelResponseRequest;
use crate::shared::server::failure::{
    ASSISTANT_PERSIST_FAILED, ENGINE_TOOL_SURFACE_FAILED, FailureCategory, FailureEnvelope,
    FailureOrigin, JOURNAL_CREATE_FAILED, MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED,
    RUNTIME_CANCELLED, RUNTIME_PERSISTENCE_ERROR,
};

use metrics::{counter, histogram};
use tracing::{error, info, instrument, trace, warn};

use self::capability_invocations::CapabilityInvocationPhaseParams;
use self::failure::{emit_turn_failure, terminalize_interrupted_turn};
pub use self::params::TurnParams;
pub(crate) use self::persistence::emit_persisted_capability_invocation_completed;
use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload,
    build_failed_message_payload, build_interrupted_message_payload, build_token_record_json,
    emit_response_complete, emit_turn_end, emit_turn_start, persist_completed_assistant_message,
    persist_model_provider_request_audit,
};
use self::turn_context::{build_turn_context, worker_relevance_query};
use crate::domains::agent::r#loop::errors::StopReason;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::r#loop::primitive_surface;
use crate::domains::agent::r#loop::stream_processor;
use crate::domains::agent::r#loop::types::TurnResult;
use crate::shared::protocol::messages::TokenUsage;

fn cancellation_failure(session_id: &str) -> FailureEnvelope {
    FailureEnvelope::new(
        RUNTIME_CANCELLED,
        FailureCategory::Cancelled,
        "Interrupted by user",
        false,
        true,
        FailureOrigin::AgentRuntime,
    )
    .with_session_id(Some(session_id.to_owned()))
}

fn determine_turn_stop_reason(
    capability_invocation_count: usize,
    llm_stop_reason: &str,
) -> Option<StopReason> {
    if capability_invocation_count == 0 {
        if llm_stop_reason == "end_turn" {
            Some(StopReason::EndTurn)
        } else {
            Some(StopReason::NoCapabilityInvocationDrafts)
        }
    } else {
        None
    }
}

#[allow(clippy::too_many_arguments)]
fn terminalize_cancellation(
    emitter: &Arc<EventEmitter>,
    persister: Option<
        &crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister,
    >,
    session_id: &str,
    turn: u32,
    run_context: &crate::domains::agent::r#loop::types::RunContext,
    sequence_counter: Option<&std::sync::atomic::AtomicI64>,
    assistant_payload: Option<serde_json::Value>,
    partial_content: Option<String>,
) -> Result<(), crate::domains::agent::r#loop::errors::RuntimeError> {
    terminalize_interrupted_turn(
        emitter,
        persister,
        session_id,
        turn,
        run_context,
        sequence_counter,
        &cancellation_failure(session_id),
        assistant_payload,
        partial_content,
    )
}

fn interrupted_turn_result(
    partial_content: Option<String>,
    token_usage: Option<TokenUsage>,
) -> TurnResult {
    TurnResult {
        success: true,
        interrupted: true,
        partial_content,
        stop_reason: Some(StopReason::Interrupted),
        token_usage,
        ..Default::default()
    }
}

fn terminalization_error_result(
    error: crate::domains::agent::r#loop::errors::RuntimeError,
    partial_content: Option<String>,
    token_usage: Option<TokenUsage>,
) -> TurnResult {
    TurnResult {
        success: false,
        error: Some(format!("failed to persist interrupted turn: {error}")),
        partial_content,
        stop_reason: Some(StopReason::Error),
        token_usage,
        ..Default::default()
    }
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

    // 1. Persist turn entry before any cancellable preparation. Compaction is
    // part of this turn's lifecycle, so a stop or failure there must close the
    // same durable ordinal rather than leaving an invisible consumed turn.
    if let Err(error) = emit_turn_start(
        emitter,
        persister,
        session_id,
        turn,
        sequence_counter,
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    ) {
        return TurnResult {
            success: false,
            error: Some(format!("failed to persist turn start: {error}")),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
    }
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

    if cancel.is_cancelled() {
        return match terminalize_cancellation(
            emitter,
            persister,
            session_id,
            turn,
            run_context,
            sequence_counter,
            None,
            None,
        ) {
            Ok(()) => interrupted_turn_result(None, None),
            Err(error) => terminalization_error_result(error, None, None),
        };
    }

    // 2. Check context capacity (compact if needed), but let Stop cancel a
    // long-running summarizer immediately and terminalize this active turn.
    let compaction_result = compaction
        .check_and_compact(
            context_manager,
            session_id,
            emitter,
            sequence_counter,
            cancel,
        )
        .await;
    match compaction_result {
        Err(crate::domains::agent::r#loop::errors::RuntimeError::Cancelled) => {
            return match terminalize_cancellation(
                emitter,
                persister,
                session_id,
                turn,
                run_context,
                sequence_counter,
                None,
                None,
            ) {
                Ok(()) => interrupted_turn_result(None, None),
                Err(error) => terminalization_error_result(error, None, None),
            };
        }
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
            let failure = e.to_failure();
            emit_turn_failure(
                emitter,
                persister,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                None,
            );
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

    if cancel.is_cancelled() {
        return match terminalize_cancellation(
            emitter,
            persister,
            session_id,
            turn,
            run_context,
            sequence_counter,
            None,
            None,
        ) {
            Ok(()) => interrupted_turn_result(None, None),
            Err(error) => terminalization_error_result(error, None, None),
        };
    }

    let relevance_query = worker_relevance_query(context_manager.messages_slice());
    let primitive_surface = match primitive_surface::resolve_provider_primitive_surface_for_query(
        engine_host,
        session_id,
        workspace_id,
        relevance_query.as_deref(),
    )
    .await
    {
        Ok(capabilities) => capabilities,
        Err(error) => {
            let error_msg = format!("failed to resolve live engine capability surface: {error}");
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
                persister,
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
        catalog_revision = primitive_surface.snapshot.catalog_revision,
        surface_hash = %primitive_surface.snapshot.surface_hash,
        fixed_tool_count = primitive_surface.snapshot.fixed_tool_count,
        projected_worker_count = primitive_surface.snapshot.projected_worker_count,
        available_worker_count = primitive_surface.snapshot.available_worker_count,
        "provider primitive surface resolved"
    );
    let worker_inbox_context = primitive_surface::take_worker_inbox_context(
        engine_host,
        &primitive_surface,
        session_id,
        turn,
        relevance_query.as_deref(),
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await;
    // 3. Build context (base from CM, external fields from RunContext/params)
    let mut context = build_turn_context(
        context_manager,
        server_origin,
        primitive_surface.capabilities.clone(),
    );
    let surface_context = primitive_surface::surface_context_primer(&primitive_surface.snapshot);
    let system_prompt = context.system_prompt.get_or_insert_with(String::new);
    if !system_prompt.is_empty() {
        system_prompt.push_str("\n\n");
    }
    system_prompt.push_str(&surface_context);
    if let Some(worker_inbox_context) = worker_inbox_context {
        let system_prompt = context.system_prompt.get_or_insert_with(String::new);
        if !system_prompt.is_empty() {
            system_prompt.push_str("\n\n");
        }
        system_prompt.push_str(&worker_inbox_context);
    }

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
                persister,
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
    ) {
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
            persister,
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
            if error.is_cancelled() || cancel.is_cancelled() {
                return match terminalize_cancellation(
                    emitter,
                    persister,
                    session_id,
                    turn,
                    run_context,
                    sequence_counter,
                    None,
                    None,
                ) {
                    Ok(()) => interrupted_turn_result(None, None),
                    Err(error) => terminalization_error_result(error, None, None),
                };
            }
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
                persister,
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
                persister,
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

    // 6. Process the complete provider stream.
    let stream_result = match stream_processor::process_stream_with_trace(
        stream,
        session_id,
        emitter,
        cancel,
        sequence_counter,
        journal.as_mut(),
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await
    {
        Ok(r) => r,
        Err(stream_failure) => {
            let error_msg = stream_failure.error.to_string();
            error!(session_id, turn, error = %error_msg, "stream failed");
            let failure = stream_failure.error.to_failure();
            let partial_content = stream_failure.partial.partial_content.clone();
            let token_usage = stream_failure.partial.token_usage.clone();
            let assistant_payload = build_failed_message_payload(
                &stream_failure.partial.message,
                stream_failure.partial.token_usage.as_ref(),
                session_id,
                turn,
                &model_name,
                provider_type,
                previous_context_baseline,
            );
            let terminalized = terminalize_interrupted_turn(
                emitter,
                persister,
                session_id,
                turn,
                run_context,
                sequence_counter,
                &failure,
                assistant_payload,
                partial_content.clone(),
            );
            if terminalized.is_ok() {
                if let Some(j) = journal.take() {
                    if let Err(cleanup_error) = j.finalize_and_delete() {
                        warn!(
                            session_id,
                            turn,
                            error = %cleanup_error,
                            "failed to finalize streaming journal after durable turn failure"
                        );
                    }
                }
            }
            return TurnResult {
                success: false,
                error: Some(if let Err(terminal_error) = terminalized {
                    format!("{error_msg}; failed to persist stream failure: {terminal_error}")
                } else {
                    error_msg
                }),
                token_usage,
                stop_reason: Some(StopReason::Error),
                partial_content,
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
        let assistant_payload = build_interrupted_message_payload(
            &stream_result.message,
            stream_result.token_usage.as_ref(),
            session_id,
            turn,
            &model_name,
            provider_type,
            previous_context_baseline,
        );

        let partial_content = stream_result.partial_content.clone();
        let terminalized = terminalize_cancellation(
            emitter,
            persister,
            session_id,
            turn,
            run_context,
            sequence_counter,
            assistant_payload,
            partial_content.clone(),
        );

        if terminalized.is_ok() {
            if let Some(j) = journal.take() {
                if let Err(e) = j.finalize_and_delete() {
                    warn!(session_id, turn, error = %e, "failed to finalize streaming journal after interruption");
                }
            }
        }

        return match terminalized {
            Ok(()) => interrupted_turn_result(partial_content, stream_result.token_usage),
            Err(error) => {
                terminalization_error_result(error, partial_content, stream_result.token_usage)
            }
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
    ) {
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
            persister,
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
            trace_id: run_context.engine_trace_id.as_ref(),
            parent_invocation_id: run_context.parent_invocation_id.as_ref(),
            worker_causal_depth: run_context.worker_causal_depth,
        },
    )
    .await;

    if let Some(error) = invocation_phase.error {
        let error_msg = format!("failed to persist capability lifecycle: {error}");
        let failure = FailureEnvelope::new(
            RUNTIME_PERSISTENCE_ERROR,
            FailureCategory::Persistence,
            error_msg.clone(),
            false,
            true,
            FailureOrigin::AgentRuntime,
        );
        emit_turn_failure(
            emitter,
            persister,
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
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    if invocation_phase.interrupted {
        let terminalized = terminalize_cancellation(
            emitter,
            persister,
            session_id,
            turn,
            run_context,
            sequence_counter,
            None,
            None,
        );
        if terminalized.is_ok()
            && let Some(j) = journal.take()
            && let Err(error) = j.finalize_and_delete()
        {
            warn!(session_id, turn, error = %error, "failed to finalize streaming journal after capability cancellation");
        }
        return match terminalized {
            Ok(()) => interrupted_turn_result(None, stream_result.token_usage),
            Err(error) => terminalization_error_result(error, None, stream_result.token_usage),
        };
    }

    // 10. Emit TurnEnd
    let duration = turn_start.elapsed().as_millis() as u64;
    if let Err(error) = emit_turn_end(
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
    ) {
        let error_msg = format!("failed to persist turn end: {error}");
        let failure = FailureEnvelope::new(
            RUNTIME_PERSISTENCE_ERROR,
            FailureCategory::Persistence,
            error_msg.clone(),
            false,
            true,
            FailureOrigin::AgentRuntime,
        );
        let terminalized = emit_turn_failure(
            emitter,
            persister,
            session_id,
            turn,
            run_context,
            sequence_counter,
            &failure,
            None,
        );
        if terminalized
            && let Some(j) = journal.take()
            && let Err(cleanup_error) = j.finalize_and_delete()
        {
            warn!(session_id, turn, error = %cleanup_error, "failed to finalize streaming journal after turn-end persistence failure");
        }
        return TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(StopReason::Error),
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    // The journal remains authoritative until the complete turn lifecycle,
    // including capability results and turn end, is durably committed.
    if let Some(j) = journal.take()
        && let Err(error) = j.finalize_and_delete()
    {
        warn!(session_id, turn, error = %error, "failed to finalize streaming journal");
    }

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
