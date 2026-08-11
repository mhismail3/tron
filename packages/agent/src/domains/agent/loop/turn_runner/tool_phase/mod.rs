//! Model-tool execution phase for one agent turn.
//!
//! This module persists provider-requested direct-tool executions, dispatches
//! kernel or worker functions with Agent identity, and writes the
//! provider-facing result message. Each registered function owns its typed
//! schema.
//! Live `tool.invocation.started` and `completed` broadcasts are emitted
//! from persisted rows with persisted row sequences; a requested batch's start
//! rows are all broadcast before any child execution future is polled. Result
//! completions commit as one provider-ordered batch. If that batch fails after
//! starts are durable, a second atomic error-completion batch closes every
//! start before the phase error propagates to the turn's canonical failure.
//! Executed and skipped completion payloads are collected in provider-request
//! order and commit as one terminal batch; no completion is broadcast when any
//! row in that batch fails. A direct operation may return a one-time credential
//! to the active model turn, but tool arguments, result content, and
//! details are redacted before any durable row or lifecycle broadcast is built.
//! Successful direct-worker completions persist only their provider-call
//! association or an already compact receipt/reference. The exact typed value
//! remains solely in the worker invocation ledger and is hydrated from that
//! ledger for one consuming provider turn.
//! Provider-requested calls in one batch execute concurrently; worker/kernel
//! implementations own their real queueing and concurrency ceilings. There is
//! no metadata-driven serialized execution mode.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::surface::ResolvedPrimitiveSurface;
use crate::domains::agent::r#loop::tool_executor;
use crate::domains::agent::r#loop::types::{StreamResult, ToolInvocationExecutionResult};
use crate::domains::session::event_store::EventType;
use crate::shared::foundation::redaction::{redact_sensitive_content, redact_sensitive_json};
use crate::shared::protocol::content::ToolResultContent;
use crate::shared::protocol::messages::{Message, ToolResultMessageContent};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{info, trace, warn};

pub(super) struct ToolPhaseParams<'a> {
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
    pub autonomous_wake_hop: u32,
    pub origin_worker_id: Option<&'a str>,
    pub origin_worker_invocation_id: Option<&'a str>,
    pub agent_id: Option<&'a str>,
    pub agent_assignment_id: Option<&'a str>,
    pub agent_execution_id: Option<&'a str>,
    pub delegated_function_grant: Option<&'a [String]>,
    pub agent_limits: Option<&'a Value>,
    pub agent_write_scopes: Option<&'a [String]>,
    pub nested_tool_ordinals: &'a crate::domains::agent::r#loop::types::NestedToolOrdinalAllocator,
}

#[derive(Default)]
pub(super) struct ToolPhaseOutcome {
    pub tool_invocations_executed: usize,
    /// A successful foreground question ends this run after its durable tool
    /// completion. The answer starts a new run from canonical session events.
    pub awaiting_user_input: bool,
    /// A pending durable coordination wait parks this run after the wait tool
    /// result is committed. A terminal message later starts a fresh run from
    /// canonical transcript and wait state; the provider loop never polls.
    pub awaiting_coordination: bool,
    pub interrupted: bool,
    pub error: Option<RuntimeError>,
}

struct ExecutedToolInvocation {
    result: ToolInvocationExecutionResult,
    provider_text: String,
}

struct DurableWorkerEvidence {
    content: String,
    details: Value,
}

fn tool_event_context_json(
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
    presentation_hints: Option<Value>,
) -> Value {
    let mut identity = json!({
        "traceId": trace_id.map(|id| id.as_str()),
        "rootInvocationId": parent_invocation_id.map(|id| id.as_str()),
    });
    if let (Some(identity), Some(presentation_hints)) =
        (identity.as_object_mut(), presentation_hints)
    {
        identity.insert("presentationHints".to_owned(), presentation_hints);
    }
    identity
}

fn result_event_context_json(
    base_identity: Value,
    result: &ToolInvocationExecutionResult,
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
        if let Some(value) = details.get("presentationHints") {
            identity.insert("presentationHints".to_owned(), value.clone());
        }
        if let Some(value) = details
            .get("presentationHints")
            .and_then(|hints| hints.get("themeColor"))
        {
            identity.insert("themeColor".to_owned(), value.clone());
        }
    }
    Value::Object(identity)
}

fn provider_result_text(result: &crate::shared::protocol::model_tools::ToolResult) -> String {
    match &result.content {
        crate::shared::protocol::model_tools::ToolResultBody::Text(text) => text.clone(),
        crate::shared::protocol::model_tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                ToolResultContent::Text { text } => Some(text.as_str()),
                ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

pub(super) async fn execute_tool_phase(params: ToolPhaseParams<'_>) -> ToolPhaseOutcome {
    if params.stream_result.tool_invocations.is_empty() {
        trace!(
            component = "agent.tool",
            agent_event = "tool_phase_skipped",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            "agent tool phase skipped"
        );
        return ToolPhaseOutcome {
            interrupted: params.cancel.is_cancelled(),
            ..Default::default()
        };
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();
    let mut started_payloads = Vec::with_capacity(params.stream_result.tool_invocations.len());
    info!(
        component = "agent.tool",
        agent_event = "tool_phase_started",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        invocation_count = params.stream_result.tool_invocations.len(),
        "agent tool phase started"
    );
    for tool_invocation in &params.stream_result.tool_invocations {
        let mut payload = json!({
            "invocationId": tool_invocation.id,
            "toolName": tool_invocation.name,
            "arguments": tool_invocation.arguments,
            "turn": params.turn,
            "runId": params.run_id,
            "traceId": params.trace_id.map(|id| id.as_str()),
            "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
        });
        if let (Some(payload), Some(identity)) = (
            payload.as_object_mut(),
            tool_event_context_json(
                params.trace_id,
                params.parent_invocation_id,
                params
                    .primitive_surface
                    .presentation_hints(&tool_invocation.name),
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
            .map(|payload| (EventType::ToolInvocationStarted, payload))
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
                    "failed to atomically persist tool starts; skipping execution"
                );
                return ToolPhaseOutcome {
                    error: Some(error),
                    ..Default::default()
                };
            }
        };
        for (row, payload) in rows.iter().zip(&started_payloads) {
            super::persistence::emit_persisted_tool_invocation_started(
                params.emitter,
                row,
                payload,
            );
        }
        trace!(
            component = "agent.tool",
            agent_event = "tool_invocation_starts_persisted",
            session_id = params.session_id,
            run_id = params.run_id.unwrap_or("none"),
            trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
            turn = params.turn,
            invocation_count = rows.len(),
            "tool invocation starts persisted atomically"
        );
    }

    super::persistence::emit_tool_invocation_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.tool_invocations,
        params.sequence_counter,
        params.trace_id,
        params.parent_invocation_id,
    );
    info!(
        component = "agent.tool",
        agent_event = "tool_invocation_batch_emitted",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        invocation_count = params.stream_result.tool_invocations.len(),
        "tool invocation batch emitted"
    );

    let mut results: Vec<Option<ExecutedToolInvocation>> =
        (0..params.stream_result.tool_invocations.len())
            .map(|_| None)
            .collect();
    let mut completion_payloads = vec![None; params.stream_result.tool_invocations.len()];
    let interrupted;

    if params.cancel.is_cancelled() {
        interrupted = true;
        let skipped = (0..params.stream_result.tool_invocations.len()).collect::<Vec<_>>();
        record_skipped_invocations(
            &skipped,
            &params,
            &mut completion_payloads,
            "agent_run_cancelled",
            "TOOL_INVOCATION_CANCELLED",
        );
    } else {
        let nested_tool_ordinals = params
            .stream_result
            .tool_invocations
            .iter()
            .map(|tool_invocation| {
                params
                    .origin_worker_invocation_id
                    .map(|_| params.nested_tool_ordinals.next(&tool_invocation.name))
            })
            .collect::<Vec<_>>();
        let futures: Vec<_> = params
            .stream_result
            .tool_invocations
            .iter()
            .enumerate()
            .map(|(idx, tool_invocation)| {
                let tool_ctx = tool_executor::ToolExecutionContext {
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
                    autonomous_wake_hop: params.autonomous_wake_hop,
                    origin_worker_id: params.origin_worker_id,
                    origin_worker_invocation_id: params.origin_worker_invocation_id,
                    agent_id: params.agent_id,
                    agent_assignment_id: params.agent_assignment_id,
                    agent_execution_id: params.agent_execution_id,
                    delegated_function_grant: params.delegated_function_grant,
                    agent_limits: params.agent_limits,
                    agent_write_scopes: params.agent_write_scopes,
                    origin_worker_tool_ordinal: nested_tool_ordinals[idx],
                };
                let working_dir = working_dir.as_str();
                async move {
                    info!(
                        component = "agent.tool",
                        agent_event = "tool_invocation_execute_started",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %tool_invocation.id,
                        tool_name = %tool_invocation.name,
                        "tool execution started"
                    );
                    let result = tool_executor::execute_tool(
                        tool_invocation,
                        params.session_id,
                        working_dir,
                        &tool_ctx,
                    )
                    .await;
                    let provider_text = super::turn_context::project_provider_result_text(
                        &provider_result_text(&result.result),
                    );
                    let presentation_hints = params
                        .primitive_surface
                        .presentation_hints(&tool_invocation.name);
                    let provider_context_text = durable_worker_evidence(
                        tool_invocation,
                        &result,
                        &provider_text,
                        presentation_hints.as_ref(),
                    )
                    .map_or_else(|| provider_text.clone(), |evidence| evidence.content);
                    info!(
                        component = "agent.tool",
                        agent_event = "tool_invocation_execute_completed",
                        session_id = params.session_id,
                        run_id = params.run_id.unwrap_or("none"),
                        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
                        turn = params.turn,
                        invocation_id = %tool_invocation.id,
                        tool_name = %tool_invocation.name,
                        duration_ms = result.duration_ms,
                        is_error = result.result.is_error.unwrap_or(false),
                        "tool execution completed"
                    );

                    let completion_payload = params.persister.map(|_| {
                        executed_completion_payload(
                            tool_invocation,
                            &result,
                            &provider_text,
                            params.run_id,
                            params.trace_id,
                            params.parent_invocation_id,
                            presentation_hints,
                        )
                    });

                    (
                        idx,
                        ExecutedToolInvocation {
                            result,
                            provider_text: provider_context_text,
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

    let completion_event_ids = match persist_completion_batch(&params, completion_payloads) {
        Ok(event_ids) => event_ids,
        Err(error) => {
            warn!(
                session_id = params.session_id,
                turn = params.turn,
                error = %error,
                "tool completion batch failed; terminalizing durable starts"
            );
            let error = match persist_failed_completion_batch(&params, &results) {
                Ok(()) => error,
                Err(repair_error) => RuntimeError::Persistence(format!(
                    "tool completion batch failed ({error}); durable terminal repair also failed ({repair_error})"
                )),
            };
            return ToolPhaseOutcome {
                interrupted,
                error: Some(error),
                ..Default::default()
            };
        }
    };

    process_tool_results(results, completion_event_ids, params, interrupted).await
}

fn executed_completion_payload(
    invocation: &crate::shared::protocol::messages::ToolInvocationDraft,
    result: &ToolInvocationExecutionResult,
    provider_text: &str,
    run_id: Option<&str>,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
    presentation_hints: Option<Value>,
) -> Value {
    let result_text = extract_result_text(result);
    let durable_result_text = redact_sensitive_content(&result_text);
    let durable_provider_text = redact_sensitive_content(provider_text);
    let is_error = result.result.is_error.unwrap_or(false);
    let durable_worker_evidence = durable_worker_evidence(
        invocation,
        result,
        provider_text,
        presentation_hints.as_ref(),
    );
    let has_durable_worker_evidence = durable_worker_evidence.is_some();
    let base_identity = tool_event_context_json(trace_id, parent_invocation_id, presentation_hints);
    let (durable_result_text, durable_details) = durable_worker_evidence.map_or_else(
        || {
            (
                durable_result_text,
                result.result.details.as_ref().map(redact_sensitive_json),
            )
        },
        |evidence| (evidence.content, Some(evidence.details)),
    );
    let mut payload = json!({
        "invocationId": invocation.id,
        "toolName": invocation.name,
        "content": durable_result_text,
        "isError": is_error,
        "duration": result.duration_ms,
        "details": durable_details,
        "runId": run_id,
        "traceId": trace_id.map(|id| id.as_str()),
        "parentInvocationId": parent_invocation_id.map(|id| id.as_str()),
    });
    if !has_durable_worker_evidence
        && durable_provider_text != durable_result_text
        && let Some(payload) = payload.as_object_mut()
    {
        payload.insert(
            "modelContextContent".to_owned(),
            Value::String(durable_provider_text),
        );
    }
    if let (Some(payload), Some(identity)) = (
        payload.as_object_mut(),
        result_event_context_json(base_identity, result)
            .as_object()
            .cloned(),
    ) {
        payload.extend(identity);
    }
    payload
}

fn durable_worker_evidence(
    invocation: &crate::shared::protocol::messages::ToolInvocationDraft,
    result: &ToolInvocationExecutionResult,
    provider_text: &str,
    presentation_hints: Option<&Value>,
) -> Option<DurableWorkerEvidence> {
    if result.result.is_error.unwrap_or(false)
        || presentation_hints
            .and_then(|hints| hints.get("surfaceKind"))
            .and_then(Value::as_str)
            != Some("worker")
    {
        return None;
    }
    let compact_value = serde_json::from_str::<Value>(provider_text)
        .ok()
        .filter(|value| {
            matches!(
                value.get("kind").and_then(Value::as_str),
                Some("worker_result_reference" | "worker_invocation_receipt")
            )
        });
    let content_value = compact_value.clone().unwrap_or_else(|| {
        json!({
            "kind":super::turn_context::WORKER_RESULT_ASSOCIATION_KIND,
            "modelToolInvocationId":invocation.id,
            "message":"The exact validated result is owned by the durable worker invocation and will be supplied once to the next model turn.",
        })
    });
    let mut details = json!({
        "kind":super::turn_context::WORKER_RESULT_ASSOCIATION_KIND,
        "modelToolInvocationId":invocation.id,
        "workerInvocationId":compact_value
            .as_ref()
            .and_then(|value| value.get("invocationId"))
            .cloned(),
    });
    if let Some(engine_outcome) = result
        .result
        .details
        .as_ref()
        .and_then(|details| details.get("engineOutcome"))
        && let Some(details) = details.as_object_mut()
    {
        details.insert("engineOutcome".to_owned(), engine_outcome.clone());
    }
    Some(DurableWorkerEvidence {
        content: redact_sensitive_content(
            &serde_json::to_string_pretty(&content_value)
                .unwrap_or_else(|_| content_value.to_string()),
        ),
        details,
    })
}

fn record_skipped_invocations(
    indices: &[usize],
    params: &ToolPhaseParams<'_>,
    completion_payloads: &mut [Option<Value>],
    reason: &str,
    code: &str,
) {
    if params.persister.is_none() {
        return;
    }
    for &idx in indices {
        let invocation = &params.stream_result.tool_invocations[idx];
        let mut payload = json!({
            "invocationId": invocation.id,
            "toolName": invocation.name,
            "content": "Tool invocation was not executed because the active turn ended.",
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
            tool_event_context_json(
                params.trace_id,
                params.parent_invocation_id,
                params
                    .primitive_surface
                    .presentation_hints(&invocation.name),
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
    params: &ToolPhaseParams<'_>,
    completion_payloads: Vec<Option<Value>>,
) -> Result<Vec<Option<String>>, RuntimeError> {
    if params.persister.is_none() {
        return Ok(vec![None; completion_payloads.len()]);
    }
    let expected_count = completion_payloads.len();
    let payloads = completion_payloads
        .into_iter()
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| {
            RuntimeError::Persistence(
                "tool phase ended without terminalizing every requested invocation".to_owned(),
            )
        })?;
    debug_assert_eq!(payloads.len(), expected_count);
    persist_and_broadcast_completion_payloads(params, &payloads)
        .map(|event_ids| event_ids.into_iter().map(Some).collect())
}

fn persist_failed_completion_batch(
    params: &ToolPhaseParams<'_>,
    results: &[Option<ExecutedToolInvocation>],
) -> Result<(), RuntimeError> {
    let Some(_) = params.persister else {
        return Ok(());
    };
    let payloads = params
        .stream_result
        .tool_invocations
        .iter()
        .enumerate()
        .map(|(idx, invocation)| {
            let executed = results[idx].as_ref();
            let mut payload = json!({
                "invocationId": invocation.id,
                "toolName": invocation.name,
                "content": "Tool invocation terminal state could not be saved; the active turn failed.",
                "isError": true,
                "duration": executed.map_or(0, |result| result.result.duration_ms),
                "details": {
                    "status": "persistence_failed",
                    "executed": executed.is_some(),
                    "failureReason": "completion_persistence_failed",
                    "code": "TOOL_COMPLETION_PERSISTENCE_FAILED",
                    "providerContextResultWritten": false
                },
                "runId": params.run_id,
                "traceId": params.trace_id.map(|id| id.as_str()),
                "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
            });
            if let (Some(payload), Some(identity)) = (
                payload.as_object_mut(),
                tool_event_context_json(
                    params.trace_id,
                    params.parent_invocation_id,
                    params
                        .primitive_surface
                        .presentation_hints(&invocation.name),
                )
                .as_object()
                .cloned(),
            ) {
                payload.extend(identity);
            }
            payload
        })
        .collect::<Vec<_>>();
    persist_and_broadcast_completion_payloads(params, &payloads).map(|_| ())
}

fn persist_and_broadcast_completion_payloads(
    params: &ToolPhaseParams<'_>,
    payloads: &[Value],
) -> Result<Vec<String>, RuntimeError> {
    let Some(persister) = params.persister else {
        return Ok(Vec::new());
    };
    let events = payloads
        .iter()
        .cloned()
        .map(|payload| (EventType::ToolInvocationCompleted, payload))
        .collect::<Vec<_>>();
    let rows = persister.append_batch_with_runtime_sequence(
        params.session_id,
        &events,
        params.sequence_counter,
    )?;
    for (row, payload) in rows.iter().zip(payloads) {
        super::persistence::emit_persisted_tool_invocation_completed(params.emitter, row, payload);
    }
    Ok(rows.into_iter().map(|row| row.id).collect())
}

async fn process_tool_results(
    mut results: Vec<Option<ExecutedToolInvocation>>,
    completion_event_ids: Vec<Option<String>>,
    params: ToolPhaseParams<'_>,
    interrupted: bool,
) -> ToolPhaseOutcome {
    let mut outcome = ToolPhaseOutcome {
        interrupted,
        ..Default::default()
    };

    for (idx, tool_invocation) in params.stream_result.tool_invocations.iter().enumerate() {
        let Some(executed) = results[idx].take() else {
            continue;
        };
        let ExecutedToolInvocation {
            result: exec_result,
            provider_text,
        } = executed;
        outcome.tool_invocations_executed += 1;
        let is_error = exec_result.result.is_error.unwrap_or(false);
        if tool_invocation.name == "request_user_input" && !is_error {
            outcome.awaiting_user_input = true;
        }
        if tool_invocation.name == "agent_wait"
            && !is_error
            && exec_result
                .result
                .details
                .as_ref()
                .and_then(|details| details.get("status"))
                .and_then(Value::as_str)
                == Some("pending")
        {
            outcome.awaiting_coordination = true;
        }

        params.context_manager.add_message_with_source(
            Message::ToolResult {
                invocation_id: tool_invocation.id.clone(),
                content: ToolResultMessageContent::Text(provider_text),
                is_error: if is_error { Some(true) } else { None },
            },
            crate::domains::agent::context::message_store::MessageAuditSource::invocation(
                tool_invocation.id.clone(),
                completion_event_ids.get(idx).cloned().flatten(),
            ),
        );
    }

    info!(
        component = "agent.tool",
        agent_event = "tool_phase_completed",
        session_id = params.session_id,
        run_id = params.run_id.unwrap_or("none"),
        trace_id = params.trace_id.map(|id| id.as_str()).unwrap_or("none"),
        turn = params.turn,
        executed_count = outcome.tool_invocations_executed,
        interrupted = outcome.interrupted,
        "agent tool phase completed"
    );
    outcome
}

fn extract_result_text(exec_result: &ToolInvocationExecutionResult) -> String {
    match &exec_result.result.content {
        crate::shared::protocol::model_tools::ToolResultBody::Text(text) => text.clone(),
        crate::shared::protocol::model_tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                ToolResultContent::Text { text } => Some(text.as_str()),
                ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

#[cfg(test)]
mod tests;
