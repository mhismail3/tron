//! Capability invocation phase for one agent turn.
//!
//! This module persists provider-requested direct-tool executions, dispatches
//! kernel or worker functions with Agent identity, and writes the
//! provider-facing result message. Each registered function owns its typed
//! schema.
//! Live `capability.invocation.started` and `completed` broadcasts are emitted
//! from persisted rows with persisted row sequences; a requested batch's start
//! rows are all broadcast before any child execution future is polled. Result
//! completions commit as one provider-ordered batch. If that batch fails after
//! starts are durable, a second atomic error-completion batch closes every
//! start before the phase error propagates to the turn's canonical failure.
//! Executed and skipped completion payloads are collected in provider-request
//! order and commit as one terminal batch; no completion is broadcast when any
//! row in that batch fails. A direct operation may return a one-time credential
//! to the active model turn, but capability arguments, result content, and
//! details are redacted before any durable row or lifecycle broadcast is built.
//! Provider-requested calls in one batch execute concurrently; worker/kernel
//! implementations own their real queueing and concurrency ceilings. There is
//! no metadata-driven serialized execution mode.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::capability_invocation_executor;
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::primitive_surface::ResolvedPrimitiveSurface;
use crate::domains::agent::r#loop::types::{CapabilityInvocationExecutionResult, StreamResult};
use crate::domains::session::event_store::EventType;
use crate::shared::foundation::redaction::{redact_sensitive_content, redact_sensitive_json};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::{CapabilityResultMessageContent, Message};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{info, trace, warn};

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
    pub invocation_abort_registry: &'a InvocationAbortRegistry,
    pub engine_host: &'a crate::engine::EngineHostHandle,
    pub run_id: Option<&'a str>,
    pub trace_id: Option<&'a crate::engine::TraceId>,
    pub parent_invocation_id: Option<&'a crate::engine::InvocationId>,
    pub worker_causal_depth: u32,
}

#[derive(Default)]
pub(super) struct CapabilityInvocationPhaseOutcome {
    pub capability_invocations_executed: usize,
    pub interrupted: bool,
    pub error: Option<RuntimeError>,
}

struct ExecutedCapabilityInvocation {
    result: CapabilityInvocationExecutionResult,
    provider_text: String,
}

fn primitive_identity_json(
    model_primitive_name: &str,
    _arguments: &serde_json::Map<String, Value>,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
) -> Value {
    json!({
        "modelPrimitiveName": model_primitive_name,
        "traceId": trace_id.map(|id| id.as_str()),
        "rootInvocationId": parent_invocation_id.map(|id| id.as_str()),
    })
}

fn result_identity_json(
    model_primitive_name: &str,
    base_identity: Value,
    result: &CapabilityInvocationExecutionResult,
) -> Value {
    let mut identity = base_identity.as_object().cloned().unwrap_or_default();
    if let Some(details) = result.result.details.as_ref() {
        for key in ["traceId", "rootInvocationId"] {
            if let Some(value) = details.get(key) {
                identity.insert(key.to_owned(), value.clone());
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

fn provider_result_text(
    result: &crate::shared::protocol::model_capabilities::CapabilityResult,
) -> String {
    match &result.content {
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
        return CapabilityInvocationPhaseOutcome {
            interrupted: params.cancel.is_cancelled(),
            ..Default::default()
        };
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();
    let mut started_payloads =
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
        started_payloads.push(redact_sensitive_json(&payload));
    }

    if let Some(persister) = params.persister {
        let events = started_payloads
            .iter()
            .cloned()
            .map(|payload| (EventType::CapabilityInvocationStarted, payload))
            .collect::<Vec<_>>();
        let rows = match persister.append_batch_with_runtime_sequence(
            params.session_id,
            &events,
            params.sequence_counter,
        ) {
            Ok(rows) => rows,
            Err(error) => {
                warn!(
                    params.session_id,
                    turn = params.turn,
                    error = %error,
                    "failed to atomically persist capability starts; skipping execution"
                );
                return CapabilityInvocationPhaseOutcome {
                    error: Some(error),
                    ..Default::default()
                };
            }
        };
        for (row, payload) in rows.iter().zip(&started_payloads) {
            super::persistence::emit_persisted_capability_invocation_started(
                params.emitter,
                row,
                payload,
            );
        }
        trace!(
            component = "agent.capability",
            agent_event = "capability_invocation_starts_persisted",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            invocation_count = rows.len(),
            "capability invocation starts persisted atomically"
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

    let mut results: Vec<Option<ExecutedCapabilityInvocation>> =
        (0..params.stream_result.capability_invocations.len())
            .map(|_| None)
            .collect();
    let mut completion_payloads = vec![None; params.stream_result.capability_invocations.len()];
    let interrupted;

    if params.cancel.is_cancelled() {
        interrupted = true;
        let skipped = (0..params.stream_result.capability_invocations.len()).collect::<Vec<_>>();
        record_skipped_invocations(
            &skipped,
            &params,
            &mut completion_payloads,
            "agent_run_cancelled",
            "CAPABILITY_INVOCATION_CANCELLED",
        );
    } else {
        let futures: Vec<_> = params
            .stream_result
            .capability_invocations
            .iter()
            .enumerate()
            .map(|(idx, capability_invocation)| {
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
                        trace_id: params.trace_id,
                        parent_invocation_id: params.parent_invocation_id,
                        worker_causal_depth: params.worker_causal_depth,
                    };
                let working_dir = working_dir.as_str();
                async move {
                    info!(
                        component = "agent.capability",
                        agent_event = "capability_invocation_execute_started",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %capability_invocation.id,
                        primitive_name = %capability_invocation.name,
                        direct_tool = %capability_invocation.name,
                        "capability invocation execution started"
                    );
                    let result = capability_invocation_executor::execute_capability_invocation(
                        capability_invocation,
                        params.session_id,
                        working_dir,
                        &capability_ctx,
                    )
                    .await;
                    let provider_text = provider_result_text(&result.result);
                    info!(
                        component = "agent.capability",
                        agent_event = "capability_invocation_execute_completed",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %capability_invocation.id,
                        primitive_name = %capability_invocation.name,
                        direct_tool = %capability_invocation.name,
                        duration_ms = result.duration_ms,
                        is_error = result.result.is_error.unwrap_or(false),
                        "capability invocation execution completed"
                    );

                    let completion_payload = params.persister.map(|_| {
                        executed_completion_payload(
                            capability_invocation,
                            &result,
                            &provider_text,
                            params.run_id,
                            params.trace_id,
                            params.parent_invocation_id,
                        )
                    });

                    (
                        idx,
                        ExecutedCapabilityInvocation {
                            result,
                            provider_text,
                        },
                        completion_payload,
                    )
                }
            })
            .collect();

        for (idx, result, completion_payload) in futures::future::join_all(futures).await {
            results[idx] = Some(result);
            completion_payloads[idx] = completion_payload;
        }
        interrupted = params.cancel.is_cancelled();
    }

    if let Err(error) = persist_completion_batch(&params, completion_payloads) {
        warn!(
            session_id = params.session_id,
            turn = params.turn,
            error = %error,
            "capability completion batch failed; terminalizing durable starts"
        );
        let error = match persist_failed_completion_batch(&params, &results) {
            Ok(()) => error,
            Err(repair_error) => RuntimeError::Persistence(format!(
                "capability completion batch failed ({error}); durable terminal repair also failed ({repair_error})"
            )),
        };
        return CapabilityInvocationPhaseOutcome {
            interrupted,
            error: Some(error),
            ..Default::default()
        };
    }

    process_capability_results(results, params, interrupted).await
}

fn executed_completion_payload(
    invocation: &crate::shared::protocol::messages::CapabilityInvocationDraft,
    result: &CapabilityInvocationExecutionResult,
    provider_text: &str,
    run_id: Option<&str>,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
) -> Value {
    let result_text = extract_result_text(result);
    let durable_result_text = redact_sensitive_content(&result_text);
    let durable_provider_text = redact_sensitive_content(provider_text);
    let is_error = result.result.is_error.unwrap_or(false);
    let base_identity = primitive_identity_json(
        &invocation.name,
        &invocation.arguments,
        trace_id,
        parent_invocation_id,
    );
    let mut payload = json!({
        "invocationId": invocation.id,
        "name": invocation.name,
        "content": durable_result_text,
        "isError": is_error,
        "duration": result.duration_ms,
        "details": result.result.details.as_ref().map(redact_sensitive_json),
        "runId": run_id,
        "traceId": trace_id.map(|id| id.as_str()),
        "parentInvocationId": parent_invocation_id.map(|id| id.as_str()),
    });
    if durable_provider_text != durable_result_text
        && let Some(payload) = payload.as_object_mut()
    {
        payload.insert(
            "modelContextContent".to_owned(),
            Value::String(durable_provider_text),
        );
    }
    if let (Some(payload), Some(identity)) = (
        payload.as_object_mut(),
        result_identity_json(&invocation.name, base_identity, result)
            .as_object()
            .cloned(),
    ) {
        payload.extend(identity);
    }
    payload
}

fn record_skipped_invocations(
    indices: &[usize],
    params: &CapabilityInvocationPhaseParams<'_>,
    completion_payloads: &mut [Option<Value>],
    reason: &str,
    code: &str,
) {
    if params.persister.is_none() {
        return;
    }
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
        completion_payloads[idx] = Some(payload);
    }
}

fn persist_completion_batch(
    params: &CapabilityInvocationPhaseParams<'_>,
    completion_payloads: Vec<Option<Value>>,
) -> Result<(), RuntimeError> {
    if params.persister.is_none() {
        return Ok(());
    }
    let expected_count = completion_payloads.len();
    let payloads = completion_payloads
        .into_iter()
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| {
            RuntimeError::Persistence(
                "capability phase ended without terminalizing every requested invocation"
                    .to_owned(),
            )
        })?;
    debug_assert_eq!(payloads.len(), expected_count);
    persist_and_broadcast_completion_payloads(params, &payloads)
}

fn persist_failed_completion_batch(
    params: &CapabilityInvocationPhaseParams<'_>,
    results: &[Option<ExecutedCapabilityInvocation>],
) -> Result<(), RuntimeError> {
    let Some(_) = params.persister else {
        return Ok(());
    };
    let payloads = params
        .stream_result
        .capability_invocations
        .iter()
        .enumerate()
        .map(|(idx, invocation)| {
            let executed = results[idx].as_ref();
            let mut payload = json!({
                "invocationId": invocation.id,
                "name": invocation.name,
                "content": "Capability invocation terminal state could not be saved; the active turn failed.",
                "isError": true,
                "duration": executed.map_or(0, |result| result.result.duration_ms),
                "details": {
                    "status": "persistence_failed",
                    "executed": executed.is_some(),
                    "failureReason": "completion_persistence_failed",
                    "code": "CAPABILITY_COMPLETION_PERSISTENCE_FAILED",
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
            payload
        })
        .collect::<Vec<_>>();
    persist_and_broadcast_completion_payloads(params, &payloads)
}

fn persist_and_broadcast_completion_payloads(
    params: &CapabilityInvocationPhaseParams<'_>,
    payloads: &[Value],
) -> Result<(), RuntimeError> {
    let Some(persister) = params.persister else {
        return Ok(());
    };
    let events = payloads
        .iter()
        .cloned()
        .map(|payload| (EventType::CapabilityInvocationCompleted, payload))
        .collect::<Vec<_>>();
    let rows = persister.append_batch_with_runtime_sequence(
        params.session_id,
        &events,
        params.sequence_counter,
    )?;
    for (row, payload) in rows.iter().zip(payloads) {
        super::persistence::emit_persisted_capability_invocation_completed(
            params.emitter,
            row,
            payload,
        );
    }
    Ok(())
}

async fn process_capability_results(
    mut results: Vec<Option<ExecutedCapabilityInvocation>>,
    params: CapabilityInvocationPhaseParams<'_>,
    interrupted: bool,
) -> CapabilityInvocationPhaseOutcome {
    let mut outcome = CapabilityInvocationPhaseOutcome {
        interrupted,
        ..Default::default()
    };

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
    }

    info!(
        component = "agent.capability",
        agent_event = "capability_phase_completed",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        executed_count = outcome.capability_invocations_executed,
        interrupted = outcome.interrupted,
        "agent capability phase completed"
    );
    outcome
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
