use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::runner::agent::capability_invocation_executor;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::agent::primitive_surface::ExecutionMode;
use crate::domains::agent::runner::agent::primitive_surface::ResolvedPrimitiveSurface;
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::orchestrator::event_persister::EventPersister;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::runner::types::{CapabilityInvocationExecutionResult, StreamResult};
use crate::domains::session::event_store::EventType;
use crate::shared::content::CapabilityResultContent;
use crate::shared::messages::{CapabilityResultMessageContent, Message};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};

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
    if let Some(operation) = operation_name_from_map(arguments)
        && let Some(object) = identity.as_object_mut()
    {
        object.insert("operationName".to_owned(), json!(operation));
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

fn operation_name_from_map(arguments: &serde_json::Map<String, Value>) -> Option<String> {
    ["operationName", "operation"].iter().find_map(|key| {
        arguments
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|operation| !operation.is_empty())
            .map(ToOwned::to_owned)
    })
}

pub(super) async fn execute_capability_invocation_phase(
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    if params.stream_result.capability_invocations.is_empty() {
        return CapabilityInvocationPhaseOutcome::default();
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();
    let mut persist_failed = false;
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
            if let Err(error) = persister
                .append_with_runtime_sequence(
                    params.session_id,
                    EventType::CapabilityInvocationStarted,
                    payload,
                    params.sequence_counter,
                )
                .await
            {
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
        }
    }

    if persist_failed {
        return CapabilityInvocationPhaseOutcome::default();
    }

    super::persistence::emit_capability_invocation_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.capability_invocations,
        params.sequence_counter,
        params.trace_id,
        params.parent_invocation_id,
    );

    let waves = build_execution_waves(
        &params.stream_result.capability_invocations,
        params.primitive_surface,
    );
    let mut results: Vec<Option<CapabilityInvocationExecutionResult>> =
        vec![None; params.stream_result.capability_invocations.len()];

    for wave in &waves {
        if params.cancel.is_cancelled() {
            break;
        }

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
                    let result = capability_invocation_executor::execute_capability_invocation(
                        capability_invocation,
                        params.session_id,
                        working_dir,
                        &capability_ctx,
                    )
                    .await;

                    if let Some(persister) = params.persister {
                        let result_text = extract_result_text(&result);
                        let model_context_content = extract_model_context_result_text(&result);
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
                        if model_context_content != result_text
                            && let Some(payload) = payload.as_object_mut()
                        {
                            payload.insert(
                                "modelContextContent".to_owned(),
                                json!(model_context_content),
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
                        if let Err(error) = persister
                            .append_with_runtime_sequence(
                                params.session_id,
                                EventType::CapabilityInvocationCompleted,
                                payload,
                                params.sequence_counter,
                            )
                            .await
                        {
                            error!(
                                params.session_id,
                                turn = params.turn,
                                invocation_id = %capability_invocation.id,
                                error = %error,
                                "failed to persist capability-result event"
                            );
                        }
                    }

                    (idx, result)
                }
            })
            .collect();

        for (idx, result) in futures::future::join_all(futures).await {
            results[idx] = Some(result);
        }
    }

    process_capability_results(results, params).await
}

async fn process_capability_results(
    mut results: Vec<Option<CapabilityInvocationExecutionResult>>,
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    let mut outcome = CapabilityInvocationPhaseOutcome::default();

    for (idx, capability_invocation) in params
        .stream_result
        .capability_invocations
        .iter()
        .enumerate()
    {
        let Some(exec_result) = results[idx].take() else {
            continue;
        };
        outcome.capability_invocations_executed += 1;
        let is_error = exec_result.result.is_error.unwrap_or(false);

        params
            .context_manager
            .add_message(Message::CapabilityResult {
                invocation_id: capability_invocation.id.clone(),
                content: extract_result_content(&exec_result),
                is_error: if is_error { Some(true) } else { None },
            });

        if exec_result.stops_turn {
            outcome.stop_turn_requested = true;
        }
    }

    outcome
}

pub(super) fn build_execution_waves(
    capability_invocations: &[crate::shared::messages::CapabilityInvocationDraft],
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
        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => text.clone(),
        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn extract_model_context_result_text(exec_result: &CapabilityInvocationExecutionResult) -> String {
    match extract_result_content(exec_result) {
        CapabilityResultMessageContent::Text(text) => text,
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn extract_result_content(
    exec_result: &CapabilityInvocationExecutionResult,
) -> CapabilityResultMessageContent {
    match &exec_result.result.content {
        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => {
            CapabilityResultMessageContent::Text(text.clone())
        }
        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
            let has_images = blocks
                .iter()
                .any(|b| matches!(b, CapabilityResultContent::Image { .. }));
            if has_images {
                CapabilityResultMessageContent::Blocks(blocks.clone())
            } else {
                CapabilityResultMessageContent::Text(
                    blocks
                        .iter()
                        .filter_map(|b| match b {
                            CapabilityResultContent::Text { text } => Some(text.as_str()),
                            CapabilityResultContent::Image { .. } => None,
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                )
            }
        }
    }
}

#[cfg(test)]
#[path = "capability_invocations/tests.rs"]
mod tests;
