//! Capability invocation phase for one agent turn.
//!
//! This module persists provider-requested primitive executions, dispatches
//! child `capability::execute` invocations, and writes the provider-facing
//! capability result message. The capability domain owns the bounded,
//! schema-validated model envelope so raw execution details stay available to
//! audit/UI persistence without entering provider context.
//! A committed context boundary is also an execution-wave boundary: later
//! serialized waves from the same provider response are not started after a
//! capability result requests the active turn to stop. Because start rows are
//! published up front for immediate UI visibility, every skipped later wave is
//! closed by a terminal non-executed completion row.
//! Live `capability.invocation.started` and `completed` broadcasts are emitted
//! from persisted rows with persisted row sequences; a requested batch's start
//! rows are all broadcast before any child execution future is polled.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::capability_invocation_executor;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::primitive_surface::ExecutionMode;
use crate::domains::agent::r#loop::primitive_surface::ResolvedPrimitiveSurface;
use crate::domains::agent::r#loop::types::{CapabilityInvocationExecutionResult, StreamResult};
use crate::domains::capability::{is_supported_operation, provider_result_text};
use crate::domains::session::event_store::{EventRow, EventType};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::{CapabilityResultMessageContent, Message};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{debug, error, info, trace, warn};

pub(super) struct CapabilityInvocationPhaseParams<'a> {
    pub turn: u32,
    pub stream_result: &'a StreamResult,
    pub context_manager: &'a mut ContextManager,
    pub primitive_surface: &'a ResolvedPrimitiveSurface,
    pub session_id: &'a str,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub workspace_id: Option<&'a str>,
    pub persister: Option<&'a EventPersister>,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    pub engine_host: Option<&'a crate::engine::EngineHostHandle>,
    pub run_id: Option<&'a str>,
    pub provider_type: &'a str,
    pub trace_id: Option<&'a crate::engine::TraceId>,
    pub parent_invocation_id: Option<&'a crate::engine::InvocationId>,
}

#[derive(Default)]
pub(super) struct CapabilityInvocationPhaseOutcome {
    pub capability_invocations_executed: usize,
    pub stop_turn_requested: bool,
}

struct ExecutedCapabilityInvocation {
    result: CapabilityInvocationExecutionResult,
    provider_text: String,
}

fn primitive_identity_json(
    model_primitive_name: &str,
    arguments: &serde_json::Map<String, Value>,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
) -> Value {
    let mut identity = json!({
        "modelPrimitiveName": model_primitive_name,
        "traceId": trace_id.map(|id| id.as_str()),
        "rootInvocationId": parent_invocation_id.map(|id| id.as_str()),
    });
    if let Some(operation) = validated_operation_name_from_map(arguments)
        && let Some(object) = identity.as_object_mut()
    {
        object.insert("operationName".to_owned(), json!(operation));
    } else if let Some(requested) = requested_operation_name_from_map(arguments)
        && let Some(object) = identity.as_object_mut()
    {
        object.insert("requestedOperationName".to_owned(), json!(requested));
    }
    identity
}

fn result_identity_json(
    model_primitive_name: &str,
    base_identity: Value,
    result: &CapabilityInvocationExecutionResult,
) -> Value {
    let mut identity = base_identity.as_object().cloned().unwrap_or_default();
    if let Some(details) = result.result.details.as_ref() {
        for key in ["operationName", "operation", "traceId", "rootInvocationId"] {
            if let Some(value) = details.get(key) {
                let identity_key = if key == "operation" {
                    "operationName"
                } else {
                    key
                };
                if identity_key == "operationName"
                    && !value.as_str().is_some_and(is_supported_operation)
                {
                    continue;
                }
                identity.insert(identity_key.to_owned(), value.clone());
            }
        }
        if let Some(value) = details.get("themeColor") {
            identity.insert("themeColor".to_owned(), value.clone());
        }
        if let Some(value) = details
            .get("presentationHints")
            .and_then(|hints| hints.get("themeColor"))
        {
            identity.insert("themeColor".to_owned(), value.clone());
        }
    }
    identity.insert("modelPrimitiveName".to_owned(), json!(model_primitive_name));
    Value::Object(identity)
}

fn validated_operation_name_from_map(arguments: &serde_json::Map<String, Value>) -> Option<String> {
    arguments
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|operation| !operation.is_empty())
        .filter(|operation| is_supported_operation(operation))
        .map(ToOwned::to_owned)
}

fn requested_operation_name_from_map(arguments: &serde_json::Map<String, Value>) -> Option<String> {
    ["operationName", "operation"].iter().find_map(|key| {
        arguments
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|operation| !operation.is_empty())
            .map(ToOwned::to_owned)
    })
}

fn provider_operation_name_from_map(arguments: &serde_json::Map<String, Value>) -> String {
    validated_operation_name_from_map(arguments)
        .or_else(|| requested_operation_name_from_map(arguments))
        .unwrap_or_else(|| "unknown".to_owned())
}

pub(super) async fn execute_capability_invocation_phase(
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    if params.stream_result.capability_invocations.is_empty() {
        trace!(
            component = "agent.capability",
            agent_event = "capability_phase_skipped",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            "agent capability phase skipped"
        );
        return CapabilityInvocationPhaseOutcome::default();
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();
    let mut persist_failed = false;
    let mut persisted_started_rows: Vec<(EventRow, Value)> =
        Vec::with_capacity(params.stream_result.capability_invocations.len());
    info!(
        component = "agent.capability",
        agent_event = "capability_phase_started",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        invocation_count = params.stream_result.capability_invocations.len(),
        "agent capability phase started"
    );
    for capability_invocation in &params.stream_result.capability_invocations {
        if let Some(persister) = params.persister {
            let mut payload = json!({
                "invocationId": capability_invocation.id,
                "name": capability_invocation.name,
                "arguments": capability_invocation.arguments,
                "turn": params.turn,
                "runId": params.run_id,
                "traceId": params.trace_id.map(|id| id.as_str()),
                "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
            });
            if let (Some(payload), Some(identity)) = (
                payload.as_object_mut(),
                primitive_identity_json(
                    &capability_invocation.name,
                    &capability_invocation.arguments,
                    params.trace_id,
                    params.parent_invocation_id,
                )
                .as_object()
                .cloned(),
            ) {
                payload.extend(identity);
            }
            let row = match persister
                .append_with_runtime_sequence(
                    params.session_id,
                    EventType::CapabilityInvocationStarted,
                    payload.clone(),
                    params.sequence_counter,
                )
                .await
            {
                Ok(row) => row,
                Err(error) => {
                    warn!(
                        params.session_id,
                        turn = params.turn,
                        invocation_id = %capability_invocation.id,
                        error = %error,
                        "failed to persist capability-invocation event; skipping execution"
                    );
                    persist_failed = true;
                    break;
                }
            };
            trace!(
                component = "agent.capability",
                agent_event = "capability_invocation_started_persisted",
                session_id = params.session_id,
                run_id = params.run_id.unwrap_or("none"),
                trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                turn = params.turn,
                invocation_id = %capability_invocation.id,
                primitive_name = %capability_invocation.name,
                "capability invocation start persisted"
            );
            persisted_started_rows.push((row, payload));
        }
    }

    if persist_failed {
        return CapabilityInvocationPhaseOutcome::default();
    }

    for (row, payload) in &persisted_started_rows {
        super::persistence::emit_persisted_capability_invocation_started(
            params.emitter,
            row,
            payload,
        );
    }

    super::persistence::emit_capability_invocation_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.capability_invocations,
        params.sequence_counter,
        params.trace_id,
        params.parent_invocation_id,
    );
    info!(
        component = "agent.capability",
        agent_event = "capability_invocation_batch_emitted",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        invocation_count = params.stream_result.capability_invocations.len(),
        "capability invocation batch emitted"
    );

    let waves = build_execution_waves(
        &params.stream_result.capability_invocations,
        params.primitive_surface,
    );
    info!(
        component = "agent.capability",
        agent_event = "capability_execution_waves_built",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        wave_count = waves.len(),
        invocation_count = params.stream_result.capability_invocations.len(),
        "capability execution waves built"
    );
    let mut results: Vec<Option<ExecutedCapabilityInvocation>> =
        (0..params.stream_result.capability_invocations.len())
            .map(|_| None)
            .collect();

    for (wave_index, wave) in waves.iter().enumerate() {
        if params.cancel.is_cancelled() {
            let skipped = waves
                .iter()
                .skip(wave_index)
                .flatten()
                .copied()
                .collect::<Vec<_>>();
            persist_skipped_invocations(
                &skipped,
                &params,
                "agent_run_cancelled",
                "CAPABILITY_INVOCATION_CANCELLED",
            )
            .await;
            break;
        }
        debug!(
            component = "agent.capability",
            agent_event = "capability_wave_started",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            wave_index,
            wave_size = wave.len(),
            "capability execution wave started"
        );

        let futures: Vec<_> = wave
            .iter()
            .map(|&idx| {
                let capability_invocation = &params.stream_result.capability_invocations[idx];
                let capability_ctx =
                    capability_invocation_executor::CapabilityInvocationExecutionContext {
                        primitive_surface: params.primitive_surface,
                        emitter: params.emitter,
                        cancel: params.cancel,
                        workspace_id: params.workspace_id,
                        sequence_counter: params.sequence_counter,
                        emit_lifecycle_events: params.persister.is_none(),
                        turn: i64::from(params.turn),
                        invocation_abort_registry: params.invocation_abort_registry,
                        engine_host: params.engine_host,
                        run_id: params.run_id,
                        provider_type: params.provider_type,
                        trace_id: params.trace_id,
                        parent_invocation_id: params.parent_invocation_id,
                    };
                let working_dir = working_dir.as_str();
                async move {
                    let operation =
                        provider_operation_name_from_map(&capability_invocation.arguments);
                    let requested_operation =
                        requested_operation_name_from_map(&capability_invocation.arguments);
                    info!(
                        component = "agent.capability",
                        agent_event = "capability_invocation_execute_started",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %capability_invocation.id,
                        primitive_name = %capability_invocation.name,
                        operation = %operation,
                        requested_operation = requested_operation.as_deref().unwrap_or("none"),
                        "capability invocation execution started"
                    );
                    let result = capability_invocation_executor::execute_capability_invocation(
                        capability_invocation,
                        params.session_id,
                        working_dir,
                        &capability_ctx,
                    )
                    .await;
                    let provider_text = provider_result_text(&operation, &result.result);
                    info!(
                        component = "agent.capability",
                        agent_event = "capability_invocation_execute_completed",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %capability_invocation.id,
                        primitive_name = %capability_invocation.name,
                        operation = %operation,
                        duration_ms = result.duration_ms,
                        is_error = result.result.is_error.unwrap_or(false),
                        stops_turn = result.stops_turn,
                        "capability invocation execution completed"
                    );

                    if let Some(persister) = params.persister {
                        let result_text = extract_result_text(&result);
                        let is_error = result.result.is_error.unwrap_or(false);
                        let base_identity = primitive_identity_json(
                            &capability_invocation.name,
                            &capability_invocation.arguments,
                            params.trace_id,
                            params.parent_invocation_id,
                        );
                        let mut payload = json!({
                            "invocationId": capability_invocation.id,
                            "name": capability_invocation.name,
                            "content": result_text,
                            "isError": is_error,
                            "duration": result.duration_ms,
                            "details": result.result.details,
                            "runId": params.run_id,
                            "traceId": params.trace_id.map(|id| id.as_str()),
                            "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
                        });
                        if provider_text != result_text
                            && let Some(payload) = payload.as_object_mut()
                        {
                            payload.insert(
                                "modelContextContent".to_owned(),
                                Value::String(provider_text.clone()),
                            );
                        }
                        if let (Some(payload), Some(identity)) = (
                            payload.as_object_mut(),
                            result_identity_json(
                                &capability_invocation.name,
                                base_identity,
                                &result,
                            )
                            .as_object()
                            .cloned(),
                        ) {
                            payload.extend(identity);
                        }
                        match persister
                            .append_with_runtime_sequence(
                                params.session_id,
                                EventType::CapabilityInvocationCompleted,
                                payload.clone(),
                                params.sequence_counter,
                            )
                            .await
                        {
                            Ok(row) => {
                                super::persistence::emit_persisted_capability_invocation_completed(
                                    params.emitter,
                                    &row,
                                    &payload,
                                );
                            }
                            Err(error) => {
                                error!(
                                    params.session_id,
                                    turn = params.turn,
                                    invocation_id = %capability_invocation.id,
                                    error = %error,
                                    "failed to persist capability-result event"
                                );
                            }
                        }
                    }

                    (
                        idx,
                        ExecutedCapabilityInvocation {
                            result,
                            provider_text,
                        },
                    )
                }
            })
            .collect();

        for (idx, result) in futures::future::join_all(futures).await {
            results[idx] = Some(result);
        }
        let wave_requested_turn_stop = wave_requests_turn_stop(wave, &results);
        debug!(
            component = "agent.capability",
            agent_event = "capability_wave_completed",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            wave_index,
            wave_size = wave.len(),
            "capability execution wave completed"
        );
        if wave_requested_turn_stop {
            info!(
                component = "agent.capability",
                agent_event = "capability_waves_stopped_at_context_boundary",
                session_id = params.session_id,
                run_id = params.run_id.unwrap_or("none"),
                trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                turn = params.turn,
                wave_index,
                "later capability waves skipped after a committed context boundary"
            );
            let skipped = waves
                .iter()
                .skip(wave_index + 1)
                .flatten()
                .copied()
                .collect::<Vec<_>>();
            persist_skipped_invocations(
                &skipped,
                &params,
                "context_boundary_committed",
                "CAPABILITY_INVOCATION_SKIPPED_AFTER_CONTEXT_BOUNDARY",
            )
            .await;
            break;
        }
    }

    process_capability_results(results, params).await
}

fn wave_requests_turn_stop(
    wave: &[usize],
    results: &[Option<ExecutedCapabilityInvocation>],
) -> bool {
    wave.iter().any(|&idx| {
        results[idx]
            .as_ref()
            .is_some_and(|executed| executed.result.stops_turn)
    })
}

async fn persist_skipped_invocations(
    indices: &[usize],
    params: &CapabilityInvocationPhaseParams<'_>,
    reason: &str,
    code: &str,
) {
    let Some(persister) = params.persister else {
        return;
    };
    for &idx in indices {
        let invocation = &params.stream_result.capability_invocations[idx];
        let mut payload = json!({
            "invocationId": invocation.id,
            "name": invocation.name,
            "content": "Capability invocation was not executed because the active turn ended.",
            "isError": true,
            "duration": 0,
            "details": {
                "status": "skipped",
                "executed": false,
                "skipReason": reason,
                "code": code,
                "providerContextResultWritten": false
            },
            "runId": params.run_id,
            "traceId": params.trace_id.map(|id| id.as_str()),
            "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
        });
        if let (Some(payload), Some(identity)) = (
            payload.as_object_mut(),
            primitive_identity_json(
                &invocation.name,
                &invocation.arguments,
                params.trace_id,
                params.parent_invocation_id,
            )
            .as_object()
            .cloned(),
        ) {
            payload.extend(identity);
        }
        match persister
            .append_with_runtime_sequence(
                params.session_id,
                EventType::CapabilityInvocationCompleted,
                payload.clone(),
                params.sequence_counter,
            )
            .await
        {
            Ok(row) => super::persistence::emit_persisted_capability_invocation_completed(
                params.emitter,
                &row,
                &payload,
            ),
            Err(error) => error!(
                session_id = params.session_id,
                invocation_id = %invocation.id,
                skip_reason = reason,
                error = %error,
                "failed to persist terminal skipped capability invocation"
            ),
        }
    }
}

async fn process_capability_results(
    mut results: Vec<Option<ExecutedCapabilityInvocation>>,
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    let mut outcome = CapabilityInvocationPhaseOutcome::default();

    for (idx, capability_invocation) in params
        .stream_result
        .capability_invocations
        .iter()
        .enumerate()
    {
        let Some(executed) = results[idx].take() else {
            continue;
        };
        let ExecutedCapabilityInvocation {
            result: exec_result,
            provider_text,
        } = executed;
        outcome.capability_invocations_executed += 1;
        let is_error = exec_result.result.is_error.unwrap_or(false);

        params
            .context_manager
            .add_message(Message::CapabilityResult {
                invocation_id: capability_invocation.id.clone(),
                content: CapabilityResultMessageContent::Text(provider_text),
                is_error: if is_error { Some(true) } else { None },
            });

        if exec_result.stops_turn {
            outcome.stop_turn_requested = true;
        }
    }

    info!(
        component = "agent.capability",
        agent_event = "capability_phase_completed",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        executed_count = outcome.capability_invocations_executed,
        stop_turn_requested = outcome.stop_turn_requested,
        "agent capability phase completed"
    );
    outcome
}

pub(super) fn build_execution_waves(
    capability_invocations: &[crate::shared::protocol::messages::CapabilityInvocationDraft],
    primitive_surface: &ResolvedPrimitiveSurface,
) -> Vec<Vec<usize>> {
    let modes: Vec<_> = capability_invocations
        .iter()
        .map(|tc| {
            primitive_surface
                .targets_by_name
                .get(&tc.name)
                .map_or(ExecutionMode::Parallel, |target| {
                    target.execution_mode.clone()
                })
        })
        .collect();

    if modes.iter().all(|m| matches!(m, ExecutionMode::Parallel)) {
        return vec![(0..capability_invocations.len()).collect()];
    }

    let mut waves: Vec<Vec<usize>> = Vec::with_capacity(4);
    waves.push(Vec::new());
    let mut group_wave: HashMap<String, usize> = HashMap::new();

    for (idx, mode) in modes.iter().enumerate() {
        match mode {
            ExecutionMode::Parallel => waves[0].push(idx),
            ExecutionMode::Serialized(group) => {
                let wave_idx = group_wave.get(group).copied().unwrap_or(0);
                while waves.len() <= wave_idx {
                    waves.push(vec![]);
                }
                waves[wave_idx].push(idx);
                let _ = group_wave.insert(group.clone(), wave_idx + 1);
            }
        }
    }

    waves.retain(|wave| !wave.is_empty());
    waves
}

fn extract_result_text(exec_result: &CapabilityInvocationExecutionResult) -> String {
    match &exec_result.result.content {
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Text(text) => {
            text.clone()
        }
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

#[cfg(test)]
mod tests;
