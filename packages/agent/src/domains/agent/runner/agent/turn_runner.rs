//! Turn runner — orchestrates a single turn: context → stream → capabilities → events.
//!
//! Capability result content is the only provider-portable channel back into
//! the model. Engine/UI/audit metadata stays in `details`, but model-facing
//! `execute` observations are projected into result text here so every provider
//! can reason about direct primitive results without gaining a second
//! capability API.

mod capability_invocations;
mod persistence;
mod provider;
mod result;
mod turn_context;

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::Instant;

use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::model::providers::ProviderHealthTracker;
use crate::domains::model::providers::provider::Provider;
use crate::shared::events::{BaseEvent, TronEvent};

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use self::capability_invocations::CapabilityInvocationPhaseParams;
use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload,
    build_interrupted_message_payload, build_token_record_json, emit_response_complete,
    emit_turn_end, emit_turn_start, persist_completed_assistant_message,
    persist_interrupted_message,
};
use self::provider::{build_stream_options, open_stream};
use self::result::determine_turn_stop_reason;
use self::turn_context::{build_turn_context, resolve_provider_primitive_surface};
use crate::domains::agent::runner::agent::compaction_handler::CompactionHandler;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::agent::stream_processor;
use crate::domains::agent::runner::errors::StopReason;
use crate::domains::agent::runner::orchestrator::event_persister::EventPersister;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::runner::orchestrator::streaming_journal::StreamingJournal;
use crate::domains::agent::runner::types::{RunContext, TurnResult};

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

/// Parameters for a single turn of the agent loop.
pub struct TurnParams<'a> {
    /// Current turn number (1-indexed).
    pub turn: u32,
    /// Context manager owning messages, rules, and token tracking.
    pub context_manager: &'a mut ContextManager,
    /// LLM provider for streaming.
    pub provider: &'a Arc<dyn Provider>,
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
    pub retry_config: Option<&'a crate::shared::retry::RetryConfig>,
    /// Optional provider health tracker for circuit-breaking.
    pub health_tracker: Option<&'a Arc<ProviderHealthTracker>>,
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
#[instrument(skip_all, fields(session_id, turn, model = params.provider.model()))]
pub async fn execute_turn(params: TurnParams<'_>) -> TurnResult {
    let TurnParams {
        turn,
        context_manager,
        provider,
        compaction,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        previous_context_baseline,
        retry_config,
        health_tracker,
        workspace_id,
        server_origin,
        sequence_counter,
        invocation_abort_registry,
        engine_host,
    } = params;
    let turn_start = Instant::now();

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
            counter!("compaction_total", "status" => "pre_turn_error").increment(1);
            return TurnResult {
                success: false,
                error: Some(format!("Compaction error: {e}")),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
        Ok(true) => {}
        Ok(false) => {}
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
    debug!(session_id, turn, "turn started");

    let primitive_surface =
        match resolve_provider_primitive_surface(engine_host, session_id, workspace_id).await {
            Ok(capabilities) => capabilities,
            Err(error) => {
                let error_msg =
                    format!("failed to resolve live engine capability surface: {error}");
                error!(session_id, turn, error = %error_msg);
                let _ = emitter.emit(TronEvent::TurnFailed {
                    base: run_base(session_id, run_context),
                    turn,
                    error: error_msg.clone(),
                    code: Some("ENGINE_TOOL_SURFACE_FAILED".into()),
                    category: Some("engine".into()),
                    recoverable: true,
                    partial_content: None,
                });
                return TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(StopReason::Error),
                    ..Default::default()
                };
            }
        };
    // 3. Build context (base from CM, external fields from RunContext/params)
    let context = build_turn_context(
        context_manager,
        run_context,
        server_origin,
        primitive_surface.capabilities.clone(),
    );

    // 4. Build stream options (thinking always enabled — provider handles model-specific config)
    let stream_options = build_stream_options(run_context, session_id);

    if let Some(persister) = persister {
        let context_blocks =
            crate::domains::model::providers::context_composition::compose_context_audit_blocks(
                &context,
            );
        let resolved_profile = run_context
            .resolved_profile
            .clone()
            .expect("RunContext.resolved_profile must be set before turn audit");
        let active_profile_name = run_context
            .profile_name
            .clone()
            .unwrap_or_else(|| resolved_profile.name.clone());
        let profile = Some(active_profile_name.as_str());
        let metadata = serde_json::json!({
            "messageCount": context.messages.len(),
            "capabilityCount": context.capabilities.as_ref().map_or(0, Vec::len),
            "catalogRevision": primitive_surface.catalog_revision.0,
            "streamOptions": &stream_options,
            "providerSurface": "execute",
                "profileChain": resolved_profile.profile_chain.clone(),
                "profileSpecHash": resolved_profile.spec_hash.clone(),
        });
        let audit = crate::domains::session::event_store::sqlite::repositories::constitution::ContextResolutionAudit {
            session_id: Some(session_id),
            turn: Some(turn),
            provider: Some(provider.provider_type().as_str()),
            model: Some(provider.model()),
            profile,
            blocks: &context_blocks,
            metadata,
        };
        let context_resolution_id = match persister.record_constitution_context_resolution(&audit) {
            Ok(id) => id,
            Err(error) => {
                let error_msg = format!("failed to audit Constitution context resolution: {error}");
                error!(session_id, turn, error = %error_msg);
                let _ = emitter.emit(TronEvent::TurnFailed {
                    base: run_base(session_id, run_context),
                    turn,
                    error: error_msg.clone(),
                    code: Some("CONSTITUTION_AUDIT_FAILED".into()),
                    category: Some("persistence".into()),
                    recoverable: false,
                    partial_content: None,
                });
                return TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(StopReason::Error),
                    ..Default::default()
                };
            }
        };

        let provider_payload = match provider.audit_payload(&context, &stream_options) {
            Ok(payload) => payload,
            Err(error) => {
                let error_msg = format!("failed to build provider payload audit: {error}");
                error!(session_id, turn, error = %error_msg);
                let _ = emitter.emit(TronEvent::TurnFailed {
                    base: run_base(session_id, run_context),
                    turn,
                    error: error_msg.clone(),
                    code: Some("PROVIDER_PAYLOAD_AUDIT_FAILED".into()),
                    category: Some("persistence".into()),
                    recoverable: false,
                    partial_content: None,
                });
                return TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(StopReason::Error),
                    ..Default::default()
                };
            }
        };
        let payload_audit =
            crate::domains::session::event_store::sqlite::repositories::constitution::ProviderPayloadAudit {
                session_id: Some(session_id),
                turn: Some(turn),
                provider: Some(provider.provider_type().as_str()),
                model: Some(provider.model()),
                profile,
                payload: &provider_payload,
                metadata: serde_json::json!({
                    "contextResolutionId": context_resolution_id,
                    "profileSpecHash": resolved_profile.spec_hash.clone(),
                    "exactProviderEnvelope": provider_payload
                        .get("exactProviderEnvelope")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(true),
                }),
            };
        if let Err(error) = persister.record_constitution_provider_payload(&payload_audit) {
            let error_msg = format!("failed to audit Constitution provider payload: {error}");
            error!(session_id, turn, error = %error_msg);
            let _ = emitter.emit(TronEvent::TurnFailed {
                base: run_base(session_id, run_context),
                turn,
                error: error_msg.clone(),
                code: Some("PROVIDER_PAYLOAD_AUDIT_FAILED".into()),
                category: Some("persistence".into()),
                recoverable: false,
                partial_content: None,
            });
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    }

    // 5. Stream from Provider (with retry if configured)
    let provider_name: &'static str = provider.provider_type().as_str();
    let model_name: String = provider.model().to_owned();
    counter!("provider_requests_total", "provider" => provider_name).increment(1);
    let request_start = Instant::now();

    let stream = match open_stream(provider, context, stream_options, cancel, retry_config).await {
        Ok(stream) => stream,
        Err(error) => {
            if let Some(ht) = health_tracker {
                ht.record_failure(provider_name);
            }
            let error_msg = error.to_string();
            let category = error.category().to_owned();
            let recoverable = error.is_retryable();
            counter!("provider_errors_total", "provider" => provider_name, "status" => category.clone()).increment(1);
            histogram!("provider_request_duration_seconds", "provider" => provider_name)
                .record(request_start.elapsed().as_secs_f64());
            warn!(
                provider = %provider_name,
                model = %provider.model(),
                status = %category,
                error = %error,
                "provider stream error"
            );

            if let Some(counter) = sequence_counter {
                let _ = emitter.emit_sequenced(
                    TronEvent::TurnFailed {
                        base: run_base(session_id, run_context),
                        turn,
                        error: error_msg.clone(),
                        code: None,
                        category: Some(category),
                        recoverable,
                        partial_content: None,
                    },
                    counter,
                );
            } else {
                let _ = emitter.emit(TronEvent::TurnFailed {
                    base: run_base(session_id, run_context),
                    turn,
                    error: error_msg.clone(),
                    code: None,
                    category: Some(category),
                    recoverable,
                    partial_content: None,
                });
            }

            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };

    // 6. Create streaming journal for crash recovery.
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
            let _ = emitter.emit(TronEvent::TurnFailed {
                base: run_base(session_id, run_context),
                turn,
                error: error_msg.clone(),
                code: Some("JOURNAL_CREATE_FAILED".into()),
                category: Some("persistence".into()),
                recoverable: false,
                partial_content: None,
            });
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };

    // 7. Process stream (drain after turn-stopping capabilities to capture token usage cleanly)
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
        Ok(r) => {
            if let Some(ht) = health_tracker {
                ht.record_success(provider_name);
            }
            r
        }
        Err(e) => {
            if let Some(ht) = health_tracker {
                ht.record_failure(provider_name);
            }
            histogram!("provider_request_duration_seconds", "provider" => provider_name)
                .record(request_start.elapsed().as_secs_f64());
            let error_msg = e.to_string();
            error!(session_id, turn, error = %error_msg, "stream failed");
            if let Some(counter) = sequence_counter {
                let _ = emitter.emit_sequenced(
                    TronEvent::TurnFailed {
                        base: run_base(session_id, run_context),
                        turn,
                        error: error_msg.clone(),
                        code: None,
                        category: Some(e.category().to_owned()),
                        recoverable: e.is_recoverable(),
                        partial_content: None,
                    },
                    counter,
                );
            } else {
                let _ = emitter.emit(TronEvent::TurnFailed {
                    base: run_base(session_id, run_context),
                    turn,
                    error: error_msg.clone(),
                    code: None,
                    category: Some(e.category().to_owned()),
                    recoverable: e.is_recoverable(),
                    partial_content: None,
                });
            }
            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };

    // Record provider request duration (covers full stream consumption)
    histogram!("provider_request_duration_seconds", "provider" => provider_name)
        .record(request_start.elapsed().as_secs_f64());

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
                provider.model(),
                provider.provider_type(),
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
        provider.provider_type(),
        session_id,
        turn,
        previous_context_baseline,
        provider.model(),
    );

    // INVARIANT: persist message.assistant BEFORE broadcasting
    // ResponseComplete. If persist fails we cannot emit because iOS would
    // see "response complete" for a message that is missing from the DB
    // on reconnect. Fail the turn with an actionable error instead.
    let has_thinking = {
        let content_has_thinking = stream_result
            .message
            .content
            .iter()
            .any(|c| matches!(c, crate::shared::content::AssistantContent::Thinking { .. }));
        content_has_thinking
    };

    let assistant_payload = build_completed_assistant_payload(
        &stream_result,
        turn,
        provider.model(),
        turn_start.elapsed().as_millis() as u64,
        has_thinking,
        provider.provider_type(),
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
        let _ = emitter.emit(TronEvent::TurnFailed {
            base: run_base(session_id, run_context),
            turn,
            error: error_msg.clone(),
            code: Some("ASSISTANT_PERSIST_FAILED".into()),
            category: Some("persistence".into()),
            recoverable: false,
            partial_content: None,
        });
        return TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
    }

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

    debug!(
        session_id,
        turn,
        duration_ms = duration,
        model = provider.model(),
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
#[path = "turn_runner/tests.rs"]
mod tests;
