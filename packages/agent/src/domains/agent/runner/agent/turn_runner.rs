//! Turn runner — orchestrates a single turn: context → stream → capabilities → events.
//!
//! Capability result content is the only provider-portable channel back into
//! the model. Engine/UI/audit metadata stays in `details`, but model-facing
//! `execute` observations are projected into result text here so every provider
//! can reason about selected targets, child invocations, approvals, and
//! resource refs without gaining a second capability API.

mod capability_invocations;
mod persistence;
mod provider;
mod result;

use std::sync::Arc;
use std::sync::atomic::AtomicI64;
use std::time::Instant;

use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::context::local_policy;
use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::capability_support::implementations::primitive_surface::{
    self, PrimitiveSurfacePolicy, ResolvedCapabilitySurface,
};
use crate::domains::model::providers::ProviderHealthTracker;
use crate::domains::model::providers::provider::Provider;
use crate::shared::events::{BaseEvent, TronEvent};
use crate::shared::messages::Context;

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use self::capability_invocations::CapabilityInvocationPhaseParams;
use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload,
    build_interrupted_message_payload, build_token_record_json, emit_response_complete,
    emit_turn_end, emit_turn_start, persist_completed_assistant_message,
    persist_interrupted_message, persist_rules_activated,
};
use self::provider::{build_stream_options, open_stream};
use self::result::determine_turn_stop_reason;
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
    /// Provider-facing primitive surface policy.
    pub primitive_surface_policy: &'a PrimitiveSurfacePolicy,
    /// Worker capability execution policy.
    pub capability_execution_policy: &'a crate::shared::profile::CapabilityExecutionPolicySpec,
    /// Optional guardrail engine for capability argument validation.
    pub guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Optional hook engine for pre/post capability invocation hooks.
    pub hooks: &'a Option<Arc<HookEngine>>,
    /// Compaction handler for pre-turn context checks.
    pub compaction: &'a CompactionHandler,
    /// Session identifier.
    pub session_id: &'a str,
    /// Event emitter for broadcasting agent lifecycle events.
    pub emitter: &'a Arc<EventEmitter>,
    /// Cancellation token for aborting the turn.
    pub cancel: &'a tokio_util::sync::CancellationToken,
    /// Run-scoped context (skill, reasoning level, subagent results).
    pub run_context: &'a RunContext,
    /// Optional event persister for inline event storage.
    pub persister: Option<&'a EventPersister>,
    /// Borrowed `Arc<EventPersister>` for cheap cloning into capability contexts.
    /// Must refer to the same persister as `persister`. Capabilities that emit
    /// progress events clone this Arc so they can persist progress durably.
    pub persister_arc: Option<&'a Arc<EventPersister>>,
    /// Previous turn's context window token count (for delta tracking).
    pub previous_context_baseline: u64,
    /// Current subagent nesting depth.
    pub subagent_depth: u32,
    /// Maximum allowed subagent nesting depth.
    pub subagent_max_depth: u32,
    /// Optional retry configuration for provider stream retries.
    pub retry_config: Option<&'a crate::shared::retry::RetryConfig>,
    /// Optional provider health tracker for circuit-breaking.
    pub health_tracker: Option<&'a Arc<ProviderHealthTracker>>,
    /// Workspace ID for scoping capability context (e.g. memory recall).
    pub workspace_id: Option<&'a str>,
    /// Server origin (e.g. `"localhost:9847"`) for system prompt.
    pub server_origin: Option<&'a str>,
    /// Optional process manager for background process execution.
    pub process_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    /// Optional unified job manager for process + subagent lifecycle.
    pub job_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>,
    >,
    /// Optional output buffer registry for process output streaming.
    pub output_buffer_registry: Option<
        &'a Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
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
        primitive_surface_policy,
        capability_execution_policy,
        guardrails,
        hooks,
        compaction,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        persister_arc,
        previous_context_baseline,
        subagent_depth,
        subagent_max_depth,
        retry_config,
        health_tracker,
        workspace_id,
        server_origin,
        process_manager,
        job_manager,
        output_buffer_registry,
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
        .check_and_compact(
            context_manager,
            hooks,
            session_id,
            emitter,
            sequence_counter,
        )
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
        Ok(true) => {
            context_manager.clear_dynamic_rules();
        }
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

    let resolved_profile = run_context
        .resolved_profile
        .as_deref()
        .expect("RunContext.resolved_profile must be set from the session execution plan");
    let context_policy = local_policy::ContextPolicy::from_entrypoint_with_spec(
        provider.provider_type(),
        &resolved_profile.spec,
        "main",
    );
    let primitive_surface = match resolve_provider_primitive_surface(
        engine_host,
        session_id,
        workspace_id,
        provider.provider_type(),
        &context_policy,
        primitive_surface_policy,
    )
    .await
    {
        Ok(capabilities) => capabilities,
        Err(error) => {
            let error_msg = format!("failed to resolve live engine capability surface: {error}");
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
    let capability_primer_context = match build_capability_primer_context(
        engine_host,
        session_id,
        workspace_id,
        &resolved_profile.spec,
        &context_policy,
    )
    .await
    {
        Ok(context) => context,
        Err(error) => {
            warn!(
                session_id,
                turn,
                error = %error,
                "capability primer generation failed; continuing without primer"
            );
            None
        }
    };

    // 3. Build context (base from CM, external fields from RunContext/params)
    let context = build_turn_context(
        context_manager,
        run_context,
        server_origin,
        &context_policy,
        primitive_surface.capabilities.clone(),
        capability_primer_context,
    );

    // 4. Build stream options (thinking always enabled — provider handles model-specific config)
    let stream_options = build_stream_options(run_context);

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
        let (
            context_policy_id,
            primitive_surface_policy_id,
            capability_execution_policy_id,
            cache_policy_id,
        ) = resolved_turn_policy_ids(&resolved_profile, provider.provider_type());
        let metadata = serde_json::json!({
            "messageCount": context.messages.len(),
            "capabilityCount": context.capabilities.as_ref().map_or(0, Vec::len),
            "catalogRevision": primitive_surface.catalog_revision.0,
            "streamOptions": &stream_options,
            "providerSurface": "preProjection",
                "profileChain": resolved_profile.profile_chain.clone(),
                "profileSpecHash": resolved_profile.spec_hash.clone(),
            "contextPolicy": context_policy_id,
            "primitiveSurfacePolicy": primitive_surface_policy_id,
            "capabilityExecutionPolicy": capability_execution_policy_id,
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
                    "cachePolicy": cache_policy_id,
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
                turn,
                provider.model(),
                provider.provider_type(),
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
            primitive_surface_policy,
            capability_execution_policy,
            guardrails,
            hooks,
            compaction,
            session_id,
            emitter,
            cancel,
            subagent_depth,
            subagent_max_depth,
            workspace_id,
            persister,
            persister_arc,
            process_manager,
            job_manager,
            output_buffer_registry,
            sequence_counter,
            provider_type: provider.provider_type(),
            execution_spec: run_context
                .resolved_profile
                .as_deref()
                .map(|profile| &profile.spec),
            profile_spec_hash: run_context
                .resolved_profile
                .as_deref()
                .map(|profile| profile.spec_hash.as_str()),
            invocation_abort_registry,
            engine_host,
            run_id: run_context.run_id.as_deref(),
            trace_id: run_context.engine_trace_id.as_ref(),
            parent_invocation_id: run_context.parent_invocation_id.as_ref(),
        },
    )
    .await;

    // 9b. Persist + broadcast batched rules.activated if any new rules activated.
    //
    // INVARIANT: persist BEFORE broadcasting. On persist failure the
    // rules-activated broadcast is skipped (turn continues — the rules are
    // already applied to the in-process context manager; only the
    // notification to iOS is lost). Unlike the assistant message path, this
    // is a secondary signal and does not warrant a hard turn failure.
    if !invocation_phase.activated_rules.is_empty() {
        let total = context_manager
            .rules_tracker()
            .activated_scoped_rules_count() as u32;
        if persist_rules_activated(
            persister,
            session_id,
            turn,
            &invocation_phase.activated_rules,
            total,
            sequence_counter,
        )
        .await
        .is_ok()
        {
            if let Some(counter) = sequence_counter {
                let _ = emitter.emit_sequenced(
                    TronEvent::RulesActivated {
                        base: run_base(session_id, run_context),
                        rules: invocation_phase.activated_rules.clone(),
                        total_activated: total,
                    },
                    counter,
                );
            } else {
                let _ = emitter.emit(TronEvent::RulesActivated {
                    base: run_base(session_id, run_context),
                    rules: invocation_phase.activated_rules.clone(),
                    total_activated: total,
                });
            }
        }
    }

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

fn build_turn_context(
    context_manager: &mut ContextManager,
    run_context: &RunContext,
    server_origin: Option<&str>,
    context_policy: &local_policy::ContextPolicy,
    primitive_surface: Vec<crate::shared::model_capabilities::ModelCapability>,
    capability_primer_context: Option<String>,
) -> Context {
    let is_local = context_policy.is_local();

    // Set volatile token estimates for accurate snapshots.
    let job_result_tokens = if context_policy.strip_job_results() {
        0
    } else {
        run_context.volatile_tokens.job_results
    };
    context_manager.set_volatile_tokens(
        run_context.volatile_tokens.skill_context,
        run_context.volatile_tokens.skill_removal,
        job_result_tokens,
    );
    // Set server origin for environment token estimation
    context_manager.set_server_origin(server_origin.map(String::from));

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.hook_context.clone_from(&run_context.hook_context);

    // ModelCapability schemas are resolved from the live engine catalog at the provider
    // request boundary. The context policy has already been applied by
    // `resolve_provider_primitive_surface`.
    context.capabilities = Some(primitive_surface);

    context
        .skill_activation_context
        .clone_from(&run_context.skill_activation_context);
    context.skill_context.clone_from(&run_context.skill_context);
    context
        .skill_removal_context
        .clone_from(&run_context.skill_removal_context);
    context.dynamic_rules_context = run_context
        .dynamic_rules_context
        .clone()
        .or(context.dynamic_rules_context);
    context.capability_primer_context = capability_primer_context;

    if context_policy.strip_memory() {
        context.memory_content = None;
    }
    if context_policy.strip_skill_index() {
        context.skill_index_context = None;
    } else {
        context
            .skill_index_context
            .clone_from(&run_context.skill_index_context);
    }
    if context_policy.strip_job_results() {
        context.job_results_context = None;
    } else {
        context
            .job_results_context
            .clone_from(&run_context.job_results);
    }
    if context_policy.rules_truncation().is_some()
        && let Some(ref rules) = context.rules_content
    {
        context.rules_content = Some(context_policy.truncate_rules(rules));
    }

    context.server_origin = server_origin.map(String::from);

    if is_local {
        let truncation_suffix = context_policy
            .spec()
            .rules_truncation_suffix
            .clone()
            .unwrap_or_default();
        let rules_truncated = context
            .rules_content
            .as_ref()
            .is_some_and(|r| r.ends_with(&truncation_suffix));
        debug!(
            provider = "ollama",
            capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
            memory_stripped = context_policy.strip_memory(),
            skill_index_stripped = context_policy.strip_skill_index(),
            job_results_stripped = context_policy.strip_job_results(),
            rules_truncated,
            "local-model turn context"
        );
    }

    context
}

async fn build_capability_primer_context(
    engine_host: Option<&crate::engine::EngineHostHandle>,
    session_id: &str,
    workspace_id: Option<&str>,
    execution_spec: &crate::shared::profile::AgentExecutionSpec,
    context_policy: &local_policy::ContextPolicy,
) -> Result<Option<String>, crate::shared::server::errors::CapabilityError> {
    let Some(host) = engine_host else {
        return Ok(None);
    };
    let capability_execution_policy_id = context_policy
        .capability_execution_policy_id()
        .unwrap_or("default");
    let Some(capability_execution_policy) =
        execution_spec.capability_execution_policy(capability_execution_policy_id)
    else {
        return Ok(None);
    };
    let primer_policy_id = capability_execution_policy
        .context_primer_policy
        .as_deref()
        .unwrap_or("coreFirstParty");
    let Some(profile_policy) = execution_spec.context_primer_policy(primer_policy_id) else {
        return Ok(None);
    };
    let policy = crate::domains::capability::registry::CapabilityContextPrimerPolicy {
        enabled: profile_policy.enabled,
        mode: profile_policy.mode.clone(),
        max_tokens: profile_policy.max_tokens,
        include_examples: profile_policy.include_examples,
        include_compact_schemas: profile_policy.include_compact_schemas,
    };
    crate::domains::capability::render_capability_primer(host, session_id, workspace_id, &policy)
        .await
}

async fn resolve_provider_primitive_surface(
    engine_host: Option<&crate::engine::EngineHostHandle>,
    session_id: &str,
    workspace_id: Option<&str>,
    provider_type: crate::shared::messages::Provider,
    context_policy: &local_policy::ContextPolicy,
    primitive_surface_policy: &PrimitiveSurfacePolicy,
) -> Result<ResolvedCapabilitySurface, String> {
    if let Some(host) = engine_host {
        return primitive_surface::resolve_provider_capabilities(
            host,
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        )
        .await;
    }

    #[cfg(test)]
    {
        let _ = (
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        );
        return Ok(ResolvedCapabilitySurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            capabilities: Vec::new(),
            targets_by_name: Default::default(),
            all_model_capability_ids: Vec::new(),
            turn_stopping_capabilities: Default::default(),
        });
    }

    #[cfg(not(test))]
    {
        let _ = (
            session_id,
            workspace_id,
            provider_type,
            context_policy,
            primitive_surface_policy,
        );
        Err("engine host is required for provider capability schema resolution".to_owned())
    }
}

fn resolved_turn_policy_ids(
    resolved_profile: &crate::shared::profile::ResolvedProfile,
    provider_type: crate::shared::messages::Provider,
) -> (String, String, String, String) {
    let spec = &resolved_profile.spec;
    let entrypoint = spec
        .entrypoints
        .get("main")
        .expect("validated profile must define entrypoints.main");
    let context_policy =
        crate::domains::agent::runner::context::local_policy::ContextPolicy::from_entrypoint_with_spec(
            provider_type,
            spec,
            "main",
        );
    let context_policy_id = context_policy.id().to_string();
    let primitive_surface_policy_id = context_policy
        .primitive_surface_policy_id()
        .map(String::from)
        .unwrap_or_else(|| entrypoint.primitive_surface_policy.clone());
    let capability_execution_policy_id = context_policy
        .capability_execution_policy_id()
        .map(String::from)
        .unwrap_or_else(|| entrypoint.capability_execution_policy.clone());
    let cache_policy_id = entrypoint.cache_policy.clone();

    (
        context_policy_id,
        primitive_surface_policy_id,
        capability_execution_policy_id,
        cache_policy_id,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::capability_support::implementations::primitive_surface::{
        EngineCapabilityTarget, ResolvedCapabilitySurface,
    };
    use crate::domains::capability_support::implementations::traits::ExecutionMode;
    use crate::engine::{EffectClass, FunctionDefinition, FunctionId, VisibilityScope, WorkerId};
    use std::collections::{BTreeMap, HashSet};

    fn surface(modes: Vec<(&str, ExecutionMode)>) -> ResolvedCapabilitySurface {
        let mut targets_by_name = BTreeMap::new();
        for (name, mode) in modes {
            let function_id = FunctionId::new(format!("capability::{}", name.to_ascii_lowercase()))
                .expect("function id");
            let function = FunctionDefinition::new(
                function_id.clone(),
                WorkerId::new("capability").expect("worker id"),
                name.to_owned(),
                VisibilityScope::System,
                EffectClass::PureRead,
            );
            let _ = targets_by_name.insert(
                name.to_owned(),
                EngineCapabilityTarget {
                    model_capability_id: name.to_owned(),
                    function_id,
                    function,
                    stops_turn: false,
                    is_interactive: false,
                    execution_mode: mode,
                },
            );
        }
        let all_model_capability_ids = targets_by_name.keys().cloned().collect();
        ResolvedCapabilitySurface {
            catalog_revision: crate::engine::CatalogRevision(0),
            capabilities: Vec::new(),
            targets_by_name,
            all_model_capability_ids,
            turn_stopping_capabilities: HashSet::new(),
        }
    }

    #[test]
    fn turn_result_success() {
        let tr = TurnResult {
            success: true,
            capability_invocations_executed: 2,
            stop_reason: Some(StopReason::EndTurn),
            ..Default::default()
        };
        assert!(tr.success);
        assert_eq!(tr.capability_invocations_executed, 2);
        assert_eq!(tr.stop_reason, Some(StopReason::EndTurn));
    }

    #[test]
    fn build_execution_waves_parallel_capabilities_share_one_wave() {
        let calls = vec![
            crate::shared::messages::CapabilityInvocationDraft::new(
                "1",
                "search",
                Default::default(),
            ),
            crate::shared::messages::CapabilityInvocationDraft::new(
                "2",
                "inspect",
                Default::default(),
            ),
        ];
        let surface = surface(vec![
            ("search", ExecutionMode::Parallel),
            ("inspect", ExecutionMode::Parallel),
        ]);
        let waves = capability_invocations::build_execution_waves(&calls, &surface);
        assert_eq!(waves, vec![vec![0, 1]]);
    }

    #[test]
    fn build_execution_waves_serialized_capabilities_are_sequenced() {
        let calls = vec![
            crate::shared::messages::CapabilityInvocationDraft::new("1", "A", Default::default()),
            crate::shared::messages::CapabilityInvocationDraft::new("2", "B", Default::default()),
            crate::shared::messages::CapabilityInvocationDraft::new("3", "C", Default::default()),
        ];
        let surface = surface(vec![
            ("A", ExecutionMode::Serialized("browser".into())),
            ("B", ExecutionMode::Serialized("browser".into())),
            ("C", ExecutionMode::Parallel),
        ]);
        let waves = capability_invocations::build_execution_waves(&calls, &surface);
        assert_eq!(waves, vec![vec![0, 2], vec![1]]);
    }

    #[test]
    fn build_execution_waves_keeps_read_primitives_from_blocking_execute() {
        let calls = vec![
            crate::shared::messages::CapabilityInvocationDraft::new(
                "1",
                "search",
                Default::default(),
            ),
            crate::shared::messages::CapabilityInvocationDraft::new(
                "2",
                "execute",
                Default::default(),
            ),
            crate::shared::messages::CapabilityInvocationDraft::new(
                "3",
                "execute",
                Default::default(),
            ),
        ];
        let surface = surface(vec![
            (
                "search",
                ExecutionMode::Serialized("capability-read".into()),
            ),
            (
                "execute",
                ExecutionMode::Serialized("capability-execute".into()),
            ),
        ]);
        let waves = capability_invocations::build_execution_waves(&calls, &surface);
        assert_eq!(waves, vec![vec![0, 1], vec![2]]);
    }
}
