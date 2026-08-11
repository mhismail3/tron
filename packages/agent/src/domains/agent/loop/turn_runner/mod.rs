//! Turn runner — orchestrates a single turn: context → stream → tools → events.
//!
//! Tool-result content is the only provider-portable channel back into
//! the model. Engine/UI/audit metadata stays in `details`. Exact textual output
//! remains durable for non-worker tools while direct-worker completions retain
//! only their provider-call association. `turn_context` resolves the canonical
//! worker result from its invocation ledger and deterministically bounds the
//! model-facing projection for both newly executed and reconstructed results,
//! so every provider can reason about direct tool evidence without accepting
//! unbounded local, web, worker, or binary-derived payloads. Every
//! provider turn resolves its tool surface from the same bounded latest-user
//! intent. Assistant plans and tool results cannot manufacture worker relevance
//! on later internal turns. A bounded generic `result_read` page is fully
//! available to the immediately following model turn; later turns retain only
//! its durable worker-result reference and exact pointer/page coordinates.
//! This one-turn evidence lease is derived from transcript order, requires no
//! shadow execution state, and lets a worker re-read evidence when genuinely
//! needed without paying to replay it on every growing-context turn.
//! Before each stream, `provider_phase` also reads the bounded Engine-authored
//! Team Context for the exact session/assignment. Canonical `message.agent`
//! events remain ordinary durable transcript evidence but render through their
//! authenticated coordination wrapper, separate from untrusted reference
//! context and from latest-user intent selection. Reusable-agent turn-end rows
//! carry the exact durable assignment identity, so usage remains attributable
//! even when offers, questions, and operator messages interleave in one chat.
//!
//! ## Concern ownership
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `provider_phase` | Resolve the deterministic live surface and trusted Team Context, lease bounded durable deliveries, finalize the typed context manifest, persist the v4 request audit, and only then open the provider stream |
//! | `stream_phase` | Journal and consume the provider stream, including durable failure and cancellation terminalization |
//! | `tool_phase` | Execute a provider-requested tool batch and persist its lifecycle |
//! | `persistence` | Build and commit assistant/turn protocol rows |
//! | `failure` | Atomically terminalize failed and interrupted turns |
//! | `turn_context` | Build provider context and bounded worker-relevance intent |
//! | `turn_worker_results` | Hydrate a fresh small direct-worker result once, then retain only its integrity reference |
//!
//! The root runner owns ordering across those phases. In particular, provider
//! bytes cannot be consumed before request-audit persistence, and a successful
//! stream cannot leave its journal until assistant, tool, and turn-end rows are
//! durable. Message bodies remain owned by the normal context/event pipeline;
//! the parallel request-local source sidecar carries only event and invocation
//! identifiers. Projection and compaction preserve matching identifiers and
//! label genuinely synthetic messages as generated instead of fabricating
//! provenance. Assistant delivery metadata may carry provenance through a
//! multi-turn tool run, but marks whether each delivery was present in that
//! exact provider turn so chat cannot contradict the request-specific audit.

mod failure;
mod params;
mod persistence;
mod provider_phase;
mod stream_phase;
mod tool_phase;
mod turn_context;
mod turn_worker_results;

pub(crate) use self::provider_phase::agent_delivery_provenance;

use std::sync::Arc;
use std::time::Instant;

use crate::shared::server::failure::{
    ASSISTANT_PERSIST_FAILED, FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_CANCELLED,
    RUNTIME_PERSISTENCE_ERROR,
};

use metrics::{counter, histogram};
use serde_json::Value;
use tracing::{error, info, instrument, trace, warn};

use self::failure::{emit_turn_failure, terminalize_interrupted_turn};
pub use self::params::TurnParams;
pub(crate) use self::persistence::emit_persisted_tool_invocation_completed;
use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload, build_token_record_json,
    emit_response_complete, emit_turn_end, emit_turn_start, persist_completed_assistant_message,
};
use self::provider_phase::{ProviderPhaseParams, open_provider_response};
use self::stream_phase::{StreamPhaseParams, process_provider_stream};
use self::tool_phase::ToolPhaseParams;
use crate::domains::agent::r#loop::errors::StopReason;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::types::TurnResult;
use crate::shared::protocol::messages::TokenUsage;

struct DeliveryLeaseGuard {
    event_store: Option<Arc<crate::domains::session::event_store::EventStore>>,
    run_id: String,
}

impl DeliveryLeaseGuard {
    fn new(
        persister: Option<
            &crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister,
        >,
        run_id: &str,
        leased_delivery_ids: &[String],
    ) -> Self {
        Self {
            event_store: (!leased_delivery_ids.is_empty())
                .then(|| persister.map(|persister| Arc::clone(persister.event_store())))
                .flatten(),
            run_id: run_id.to_owned(),
        }
    }

    fn observe(
        &mut self,
        session_id: &str,
        turn: u32,
    ) -> Result<(), crate::domains::agent::r#loop::errors::RuntimeError> {
        if let Some(event_store) = self.event_store.as_ref() {
            event_store
                .observe_agent_deliveries(session_id, &self.run_id, turn)
                .map_err(|error| {
                    crate::domains::agent::r#loop::errors::RuntimeError::Persistence(format!(
                        "failed to mark agent deliveries observed: {error}"
                    ))
                })?;
            self.event_store = None;
        }
        Ok(())
    }
}

impl Drop for DeliveryLeaseGuard {
    fn drop(&mut self) {
        if let Some(event_store) = self.event_store.take() {
            let _ = event_store.release_agent_delivery_leases(&self.run_id);
        }
    }
}

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
    tool_invocation_count: usize,
    llm_stop_reason: &str,
    awaiting_external_input: bool,
) -> Option<StopReason> {
    if awaiting_external_input {
        Some(StopReason::EndTurn)
    } else if tool_invocation_count == 0 {
        if llm_stop_reason == "end_turn" {
            Some(StopReason::EndTurn)
        } else {
            Some(StopReason::NoToolInvocationDrafts)
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
        (run_context.delivery_wake_turn == Some(turn))
            .then(|| {
                let pending = run_context.pending_delivery_provenance.lock();
                (!pending.is_empty()).then(|| {
                    serde_json::json!({
                        "deliveries":pending.clone(),
                    })
                })
            })
            .flatten(),
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

    // 2. Canonicalize worker-result history before token estimation or
    // compaction. Missing/corrupt fresh evidence is a storage failure and must
    // stop before any provider request can observe divergent context.
    let fresh_worker_results = match turn_context::canonicalize_worker_result_context(
        context_manager,
        engine_host,
        session_id,
        run_context.engine_trace_id.as_ref(),
        run_context.parent_invocation_id.as_ref(),
    )
    .await
    {
        Ok(fresh) => fresh,
        Err(error) => {
            let error_msg = format!("failed to project durable worker results: {error}");
            let failure = FailureEnvelope::new(
                RUNTIME_PERSISTENCE_ERROR,
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

    // 3. Check context capacity (compact if needed), but let Stop cancel a
    // long-running summarizer immediately and terminalize this active turn.
    let compaction_result = compaction
        .check_and_compact(
            context_manager,
            session_id,
            emitter,
            sequence_counter,
            cancel,
            run_context,
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

    let prepared_provider = match open_provider_response(ProviderPhaseParams {
        turn,
        context_manager,
        responder,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        retry_config,
        server_origin,
        sequence_counter,
        engine_host,
        fresh_worker_results: &fresh_worker_results,
    })
    .await
    {
        Ok(prepared) => prepared,
        Err(result) => return result,
    };
    let primitive_surface = prepared_provider.primitive_surface;
    let response = prepared_provider.response;
    let mut delivery_lease_guard =
        DeliveryLeaseGuard::new(persister, run_id, &prepared_provider.leased_delivery_ids);
    let processed_stream = match process_provider_stream(StreamPhaseParams {
        turn,
        response,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        previous_context_baseline,
        sequence_counter,
    })
    .await
    {
        Ok(processed) => processed,
        Err(result) => return result,
    };
    let response_info = processed_stream.info;
    let provider_type = response_info.provider_type;
    let model_name = response_info.model;
    let stream_result = processed_stream.stream_result;
    let mut journal = Some(processed_stream.journal);

    // Build token record + cost BEFORE ResponseComplete (iOS attaches stats from this)
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

    let mut assistant_payload = build_completed_assistant_payload(
        &stream_result,
        turn,
        &model_name,
        turn_start.elapsed().as_millis() as u64,
        has_thinking,
        provider_type,
        token_record_json.as_ref(),
        cost,
    );
    if let Some(agent_id) = run_context.agent_id.as_deref() {
        assistant_payload["agentId"] = Value::String(agent_id.to_owned());
    }
    if let Some(assignment_id) = run_context.agent_assignment_id.as_deref() {
        assistant_payload["agentAssignmentId"] = Value::String(assignment_id.to_owned());
    }
    if let Some(execution_id) = run_context.agent_execution_id.as_deref() {
        assistant_payload["agentExecutionId"] = Value::String(execution_id.to_owned());
    }
    let agent_delivery_continuation = {
        let mut pending = run_context.pending_delivery_provenance.lock();
        for delivery in &prepared_provider.leased_delivery_provenance {
            let delivery_id = delivery.get("deliveryId");
            if !pending
                .iter()
                .any(|existing| existing.get("deliveryId") == delivery_id)
            {
                pending.push(delivery.clone());
            }
        }
        assistant_delivery_continuation(&pending, &prepared_provider.leased_delivery_provenance)
    };
    if let Some(continuation) = agent_delivery_continuation.as_ref() {
        assistant_payload["agentDeliveryContinuation"] = continuation.clone();
    }

    let assistant_event = match persist_completed_assistant_message(
        persister,
        session_id,
        assistant_payload,
        sequence_counter,
    ) {
        Ok(event) => event,
        Err(error) => {
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
    };
    if stream_result.tool_invocations.is_empty() {
        run_context.pending_delivery_provenance.lock().clear();
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
    let _ = add_assistant_message_to_context(
        context_manager,
        &stream_result,
        assistant_event.map(|event| event.id),
    );
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
        agent_delivery_continuation,
    );

    let invocation_phase = tool_phase::execute_tool_phase(ToolPhaseParams {
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
        autonomous_wake_hop: run_context.autonomous_wake_hop,
        origin_worker_id: run_context.origin_worker_id.as_deref(),
        origin_worker_invocation_id: run_context.origin_worker_invocation_id.as_deref(),
        agent_id: run_context.agent_id.as_deref(),
        agent_assignment_id: run_context.agent_assignment_id.as_deref(),
        agent_execution_id: run_context.agent_execution_id.as_deref(),
        delegated_function_grant: run_context.delegated_function_grant.as_deref(),
        agent_limits: run_context.agent_limits.as_ref(),
        agent_write_scopes: run_context.agent_write_scopes.as_deref(),
        nested_tool_ordinals: &run_context.nested_tool_ordinals,
    })
    .await;

    if let Some(error) = invocation_phase.error {
        let error_msg = format!("failed to persist tool lifecycle: {error}");
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
            warn!(session_id, turn, error = %error, "failed to finalize streaming journal after tool cancellation");
        }
        return match terminalized {
            Ok(()) => interrupted_turn_result(None, stream_result.token_usage),
            Err(error) => terminalization_error_result(error, None, stream_result.token_usage),
        };
    }

    // Commit the terminal turn row after every tool completion is durable.
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
        run_context.agent_assignment_id.as_deref(),
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

    // Prepared delivery context becomes observed only after the assistant,
    // tools, and terminal turn row are all durable. Every earlier return drops
    // the guard and restores the leases to pending.
    if let Err(error) = delivery_lease_guard.observe(session_id, turn) {
        return TurnResult {
            success: false,
            error: Some(error.to_string()),
            stop_reason: Some(StopReason::Error),
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    // The journal remains authoritative until the complete turn lifecycle,
    // including tool results and turn end, is durably committed.
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
        tools = invocation_phase.tool_invocations_executed,
        has_thinking,
        "turn completed"
    );

    // Record turn metrics
    counter!("agent_turns_total", "model" => model_name.clone()).increment(1);
    histogram!("agent_turn_duration_seconds", "model" => model_name.clone())
        .record(turn_start.elapsed().as_secs_f64());

    // Determine stop reason for this turn
    let stop_reason = determine_turn_stop_reason(
        stream_result.tool_invocations.len(),
        &stream_result.stop_reason,
        invocation_phase.awaiting_user_input || invocation_phase.awaiting_coordination,
    );

    let context_window_tokens = token_record_json
        .as_ref()
        .and_then(|r| r["computed"]["contextWindowTokens"].as_u64());

    TurnResult {
        success: true,
        tool_invocations_executed: invocation_phase.tool_invocations_executed,
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

/// Preserve run-level delivery provenance on the final visible assistant
/// response without claiming that every carried delivery was present in that
/// specific provider request. Session Context remains request-specific; this
/// presentation sidecar makes the distinction explicit for chat.
fn assistant_delivery_continuation(
    pending: &[serde_json::Value],
    included_this_turn: &[serde_json::Value],
) -> Option<serde_json::Value> {
    if pending.is_empty() {
        return None;
    }
    let deliveries = pending
        .iter()
        .cloned()
        .map(|mut delivery| {
            let delivery_id = delivery.get("deliveryId");
            let included = included_this_turn
                .iter()
                .any(|current| current.get("deliveryId") == delivery_id);
            delivery["includedInThisTurn"] = serde_json::Value::Bool(included);
            delivery
        })
        .collect::<Vec<_>>();
    Some(serde_json::json!({ "deliveries": deliveries }))
}

#[cfg(test)]
mod delivery_continuation_tests {
    use super::{assistant_delivery_continuation, determine_turn_stop_reason};
    use crate::domains::agent::r#loop::errors::StopReason;
    use serde_json::json;

    #[test]
    fn distinguishes_current_request_delivery_from_carried_run_provenance() {
        let first = json!({"deliveryId":"delivery-1","sourceKind":"worker_result"});
        let second = json!({"deliveryId":"delivery-2","sourceKind":"agent_message"});
        let continuation =
            assistant_delivery_continuation(&[first.clone(), second], &[first]).unwrap();

        assert_eq!(continuation["deliveries"][0]["includedInThisTurn"], true);
        assert_eq!(continuation["deliveries"][1]["includedInThisTurn"], false);
    }

    #[test]
    fn omits_empty_delivery_continuation() {
        assert!(assistant_delivery_continuation(&[], &[]).is_none());
    }

    #[test]
    fn successful_user_input_request_stops_before_another_provider_turn() {
        assert_eq!(
            determine_turn_stop_reason(1, "tool_use", true),
            Some(StopReason::EndTurn)
        );
        assert_eq!(determine_turn_stop_reason(1, "tool_use", false), None);
    }
}
