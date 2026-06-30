use std::collections::HashMap;
use std::sync::atomic::AtomicI64;
use std::sync::{Arc, LazyLock};

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::capability_invocation_executor;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::primitive_surface::ExecutionMode;
use crate::domains::agent::r#loop::primitive_surface::ResolvedPrimitiveSurface;
use crate::domains::agent::r#loop::types::{CapabilityInvocationExecutionResult, StreamResult};
use crate::domains::capability::is_supported_operation;
use crate::domains::session::event_store::EventType;
use crate::shared::foundation::redaction::redact_sensitive_content;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::{CapabilityResultMessageContent, Message};
use regex::Regex;
use serde_json::{Map, Value, json};
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
    let mut results: Vec<Option<CapabilityInvocationExecutionResult>> =
        vec![None; params.stream_result.capability_invocations.len()];

    for (wave_index, wave) in waves.iter().enumerate() {
        if params.cancel.is_cancelled() {
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
                        validated_operation_name_from_map(&capability_invocation.arguments)
                            .unwrap_or_else(|| "unknown".to_owned());
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

const MODEL_CONTEXT_EVIDENCE_MAX_CHARS: usize = 12_000;
const MODEL_CONTEXT_STRING_MAX_CHARS: usize = 800;
const MODEL_CONTEXT_ARRAY_MAX_ITEMS: usize = 20;
const MODEL_CONTEXT_OBJECT_MAX_KEYS: usize = 80;

fn extract_result_content(
    exec_result: &CapabilityInvocationExecutionResult,
) -> CapabilityResultMessageContent {
    let projected = model_context_evidence(exec_result.result.details.as_ref());
    match &exec_result.result.content {
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Text(text) => {
            CapabilityResultMessageContent::Text(append_model_context_evidence(
                text.clone(),
                projected,
            ))
        }
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
            let has_images = blocks
                .iter()
                .any(|b| matches!(b, CapabilityResultContent::Image { .. }));
            if has_images {
                let mut blocks = blocks.clone();
                if let Some(projected) = projected {
                    blocks.push(CapabilityResultContent::text(projected));
                }
                CapabilityResultMessageContent::Blocks(blocks)
            } else {
                let text = blocks
                    .iter()
                    .filter_map(|b| match b {
                        CapabilityResultContent::Text { text } => Some(text.as_str()),
                        CapabilityResultContent::Image { .. } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                CapabilityResultMessageContent::Text(append_model_context_evidence(text, projected))
            }
        }
    }
}

fn append_model_context_evidence(text: String, projected: Option<String>) -> String {
    let Some(projected) = projected else {
        return text;
    };
    if text.is_empty() {
        projected
    } else {
        format!("{text}\n\n{projected}")
    }
}

fn model_context_evidence(details: Option<&Value>) -> Option<String> {
    let details = details?;
    if let Some(projected) = project_error_evidence(details) {
        return render_model_context_evidence(projected);
    }
    let operation = details
        .get("primitiveOperation")
        .and_then(Value::as_str)
        .or_else(|| details.get("operation").and_then(Value::as_str))?;
    let projected = match operation {
        "catalog_search" | "catalog_inspect" => project_catalog_evidence(details),
        "log_recent" => project_log_evidence(details),
        "trace_list" | "trace_get" => project_trace_evidence(details),
        operation if projects_metadata_operation(operation) => {
            project_metadata_operation_evidence(operation, details)
        }
        _ => None,
    }?;
    render_model_context_evidence(projected)
}

fn render_model_context_evidence(projected: Value) -> Option<String> {
    let mut text = serde_json::to_string_pretty(&json!({
        "modelContextEvidence": projected
    }))
    .ok()?;
    if text.len() > MODEL_CONTEXT_EVIDENCE_MAX_CHARS {
        text.truncate(MODEL_CONTEXT_EVIDENCE_MAX_CHARS);
        text.push_str("\n... [model context evidence truncated]");
    }
    Some(text)
}

fn project_catalog_evidence(details: &Value) -> Option<Value> {
    let discovery = details.get("catalogDiscovery")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    copy_key(&mut projected, discovery, "kind");
    copy_key(&mut projected, discovery, "id");
    copy_key(&mut projected, discovery, "aliasResolvedFrom");
    copy_key(&mut projected, discovery, "summary");
    if let Some(guidance) = discovery.get("modelFacingGuidance") {
        projected.insert(
            "modelFacingGuidance".to_owned(),
            project_model_facing_guidance(guidance),
        );
    }
    copy_key(&mut projected, discovery, "modelFacingInvocation");
    if let Some(functions) = discovery.get("functions").and_then(Value::as_array) {
        projected.insert(
            "functions".to_owned(),
            Value::Array(
                functions
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_catalog_function)
                    .collect(),
            ),
        );
        if functions.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "functionsOmitted".to_owned(),
                json!(functions.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    Some(Value::Object(projected))
}

fn project_model_facing_guidance(guidance: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["catalogInspect", "capabilityExecute"] {
        copy_key(&mut projected, guidance, key);
    }
    if let Some(operations) = guidance
        .get("supportedExecuteOperations")
        .and_then(Value::as_array)
    {
        let returned = operations
            .iter()
            .filter_map(Value::as_str)
            .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
            .map(|operation| Value::String(operation.to_owned()))
            .collect::<Vec<_>>();
        projected.insert(
            "supportedExecuteOperations".to_owned(),
            json!({
                "total": operations.len(),
                "returned": returned,
                "truncated": operations.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
                "omitted": operations.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
                "maxItems": MODEL_CONTEXT_ARRAY_MAX_ITEMS
            }),
        );
    }
    Value::Object(projected)
}

fn project_catalog_function(function: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "id",
        "name",
        "description",
        "ownerWorkerId",
        "visibility",
        "effectClass",
        "riskLevel",
        "modelFacingInvocation",
    ] {
        copy_key(&mut projected, function, key);
    }
    Value::Object(projected)
}

fn project_log_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    let entries = details.get("entries")?.as_array()?;
    projected.insert(
        "entries".to_owned(),
        Value::Array(
            entries
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(|entry| {
                    let mut projected = Map::new();
                    for key in [
                        "id",
                        "timestamp",
                        "level",
                        "component",
                        "message",
                        "sessionId",
                        "traceId",
                        "errorMessage",
                    ] {
                        copy_key(&mut projected, entry, key);
                    }
                    Value::Object(projected)
                })
                .collect(),
        ),
    );
    if entries.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
        projected.insert(
            "entriesOmitted".to_owned(),
            json!(entries.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
        );
    }
    Some(Value::Object(projected))
}

fn project_trace_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    if let Some(records) = details.get("records").and_then(Value::as_array) {
        projected.insert(
            "records".to_owned(),
            Value::Array(
                records
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_trace_record)
                    .collect(),
            ),
        );
        if records.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "recordsOmitted".to_owned(),
                json!(records.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    if let Some(record) = details.get("record") {
        projected.insert("record".to_owned(), project_trace_record(record));
    }
    Some(Value::Object(projected))
}

fn project_trace_record(record: &Value) -> Value {
    let mut projected = Map::new();
    let metadata = record
        .get("metadata")
        .and_then(|metadata| metadata.get("dev.tron"))
        .unwrap_or(&Value::Null);
    for key in [
        "id",
        "traceRecordId",
        "traceId",
        "invocationId",
        "providerInvocationId",
        "parentInvocationId",
        "modelPrimitiveName",
        "operation",
        "status",
        "timestamp",
        "completedAt",
        "durationMs",
        "sessionId",
        "turn",
    ] {
        copy_key(&mut projected, record, key);
        copy_key(&mut projected, metadata, key);
    }
    if let Some(error) = record.get("error").or_else(|| metadata.get("error")) {
        if let Some(error) = project_failure_value(error) {
            projected.insert("error".to_owned(), error);
        }
    }
    Value::Object(projected)
}

fn project_error_evidence(details: &Value) -> Option<Value> {
    let failure = details.get("failure")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "modelPrimitiveName");
    copy_key(&mut projected, details, "providerInvocationId");
    copy_key(&mut projected, details, "primitiveTargetId");
    if let Some(failure) = project_failure_value(failure) {
        projected.extend(failure.as_object()?.clone());
    }
    Some(Value::Object(projected))
}

fn project_failure_value(failure: &Value) -> Option<Value> {
    let mut projected = Map::new();
    for key in [
        "code",
        "category",
        "origin",
        "retryable",
        "recoverable",
        "message",
        "suggestion",
    ] {
        copy_key(&mut projected, failure, key);
    }
    if let Some(details) = failure.get("details") {
        let mut failure_details = Map::new();
        copy_error_detail_keys(&mut failure_details, details);
        if !failure_details.is_empty() {
            projected.insert(
                "details".to_owned(),
                Value::Object(failure_details.into_iter().take(24).collect()),
            );
        }
    }
    Some(Value::Object(projected))
}

fn copy_error_detail_keys(projected: &mut Map<String, Value>, value: &Value) {
    let Some(object) = value.as_object() else {
        return;
    };
    for (key, field) in object {
        if matches!(
            key.as_str(),
            "code"
                | "path"
                | "field"
                | "functionId"
                | "direction"
                | "operation"
                | "required"
                | "requiredFields"
                | "missingFields"
                | "expected"
                | "actual"
        ) {
            projected.insert(key.clone(), bounded_model_context_value(field));
        } else if field.is_object() {
            copy_error_detail_keys(projected, field);
        }
    }
}

fn projects_metadata_operation(operation: &str) -> bool {
    matches!(
        operation,
        "goal_create"
            | "goal_list"
            | "goal_inspect"
            | "goal_cancel"
            | "question_create"
            | "question_list"
            | "question_inspect"
            | "question_answer"
            | "state_get"
            | "state_set"
            | "state_list"
            | "filesystem_write"
            | "filesystem_edit"
            | "filesystem_apply_patch"
            | "media_create"
            | "media_list"
            | "media_inspect"
            | "media_archive"
            | "memory_status"
            | "memory_list"
            | "memory_inspect"
            | "memory_query_list"
            | "memory_query_inspect"
            | "memory_decision_list"
            | "memory_decision_inspect"
            | "import_history_record"
            | "import_history_list"
            | "import_history_inspect"
            | "repository_tree_snapshot"
            | "repository_tree_list"
            | "repository_tree_inspect"
            | "import_preview_record"
            | "import_preview_list"
            | "import_preview_inspect"
            | "program_execution_record"
            | "program_execution_list"
            | "program_execution_inspect"
            | "prompt_artifact_record"
            | "prompt_artifact_list"
            | "prompt_artifact_inspect"
            | "update_diagnostic_record"
            | "update_diagnostic_list"
            | "update_diagnostic_inspect"
            | "web_research_request_record"
            | "web_research_request_list"
            | "web_research_request_inspect"
            | "web_research_review_record"
            | "web_research_review_list"
            | "web_research_review_inspect"
            | "web_research_source_record"
            | "web_research_source_list"
            | "web_research_source_inspect"
            | "module_list"
            | "module_inspect"
            | "module_proposal_record"
            | "module_proposal_list"
            | "module_proposal_inspect"
            | "module_validation_record"
            | "module_validation_list"
            | "module_validation_inspect"
            | "module_install_request_record"
            | "module_install_request_list"
            | "module_install_request_inspect"
            | "module_install_decision_record"
            | "module_install_decision_list"
            | "module_install_decision_inspect"
            | "module_dependency_request_record"
            | "module_dependency_request_list"
            | "module_dependency_request_inspect"
            | "module_dependency_decision_record"
            | "module_dependency_decision_list"
            | "module_dependency_decision_inspect"
            | "module_dependency_policy_activate"
            | "module_dependency_policy_list"
            | "module_dependency_policy_inspect"
            | "module_lifecycle_request"
            | "module_lifecycle_decision"
            | "module_lifecycle_list"
            | "module_lifecycle_inspect"
            | "module_runtime_request"
            | "module_runtime_list"
            | "module_runtime_inspect"
            | "module_runtime_cancel"
            | "module_program_execution_start"
            | "module_program_execution_status"
            | "module_program_execution_cancel"
            | "module_program_execution_cleanup"
            | "procedural_definition_record"
            | "procedural_state_list"
            | "procedural_state_inspect"
            | "procedural_activation_request_record"
            | "procedural_activation_request_list"
            | "procedural_activation_request_inspect"
            | "procedural_activation_decision_record"
            | "procedural_activation_decision_list"
            | "procedural_activation_decision_inspect"
            | "tool_source_list"
            | "tool_source_inspect"
            | "worker_package_list"
            | "worker_package_inspect"
    )
}

fn project_metadata_operation_evidence(operation: &str, details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected.insert("operation".to_owned(), json!(operation));
    for (key, value) in details.as_object()? {
        if key == "primitiveOperation" || key == "status" {
            continue;
        }
        if let Some(projected_value) = project_safe_metadata_value(key, value, 0) {
            projected.insert(key.clone(), projected_value);
        }
        if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
            break;
        }
    }
    (projected.len() > 2).then_some(Value::Object(projected))
}

fn project_safe_metadata_value(key: &str, value: &Value, depth: usize) -> Option<Value> {
    if depth > 5 || denied_model_context_key(key) {
        return None;
    }
    if safe_scalar_metadata_key(key) {
        return bounded_safe_scalar_metadata_value(value);
    }
    match value {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (child_key, child_value) in object {
                if let Some(value) = project_safe_metadata_value(child_key, child_value, depth + 1)
                {
                    projected.insert(child_key.clone(), value);
                }
                if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
                    break;
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::Array(items) if safe_array_metadata_key(key) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| project_array_item_metadata(item, depth + 1))
                .collect::<Vec<_>>();
            let mut wrapper = Map::new();
            wrapper.insert("total".to_owned(), json!(items.len()));
            wrapper.insert("returned".to_owned(), json!(projected.len()));
            wrapper.insert(
                "truncated".to_owned(),
                json!(items.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
            wrapper.insert(
                "omitted".to_owned(),
                json!(items.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS)),
            );
            wrapper.insert("items".to_owned(), Value::Array(projected));
            Some(Value::Object(wrapper))
        }
        _ => None,
    }
}

fn bounded_safe_scalar_metadata_value(value: &Value) -> Option<Value> {
    match value {
        Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
            Some(bounded_model_context_value(value))
        }
        Value::Array(items) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| match item {
                    Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
                        Some(bounded_model_context_value(item))
                    }
                    Value::Object(_) | Value::Array(_) => None,
                })
                .collect::<Vec<_>>();
            (!projected.is_empty()).then_some(Value::Array(projected))
        }
        Value::Object(_) => None,
    }
}

fn project_array_item_metadata(item: &Value, depth: usize) -> Option<Value> {
    match item {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (key, value) in object {
                if let Some(value) = project_safe_metadata_value(key, value, depth + 1) {
                    projected.insert(key.clone(), value);
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::String(value) => Some(Value::String(truncate_model_context_string(value))),
        Value::Bool(_) | Value::Number(_) | Value::Null => Some(bounded_model_context_value(item)),
        Value::Array(_) => None,
    }
}

fn safe_array_metadata_key(key: &str) -> bool {
    matches!(
        key,
        "records"
            | "entries"
            | "items"
            | "results"
            | "resourceRefs"
            | "resources"
            | "versions"
            | "modules"
            | "media"
            | "memories"
            | "queries"
            | "decisions"
            | "requests"
            | "reviews"
            | "sources"
            | "goals"
            | "questions"
            | "artifacts"
            | "programs"
            | "snapshots"
            | "reports"
            | "refs"
            | "traceRefs"
            | "replayRefs"
    )
}

fn safe_scalar_metadata_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    matches!(
        key,
        "schemaVersion"
            | "primitiveOperation"
            | "operation"
            | "status"
            | "state"
            | "lifecycle"
            | "kind"
            | "type"
            | "role"
            | "title"
            | "summary"
            | "description"
            | "reason"
            | "decision"
            | "scope"
            | "namespace"
            | "key"
            | "mode"
            | "enabled"
            | "active"
            | "configured"
            | "createdAt"
            | "updatedAt"
            | "recordedAt"
            | "completedAt"
            | "startedAt"
            | "timestamp"
            | "count"
            | "total"
            | "returned"
            | "limit"
            | "truncated"
            | "omitted"
            | "hasMore"
            | "networkPolicy"
            | "remotePolicy"
            | "selector"
            | "selectors"
            | "resourceSelectors"
            | "requiredAuthorityScopes"
            | "requiredScopes"
            | "requiredSelectors"
            | "current"
            | "currentVersionId"
            | "versionId"
            | "expectedCurrentVersionId"
    ) || (lower.ends_with("id")
        && !lower.contains("grant")
        && !lower.contains("authority")
        && !lower.contains("secret")
        && !lower.contains("token"))
        || (lower.ends_with("ids")
            && !lower.contains("grant")
            && !lower.contains("authority")
            && !lower.contains("secret")
            && !lower.contains("token"))
        || lower.ends_with("versionid")
        || lower.ends_with("resourceid")
}

fn denied_model_context_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower.contains("grant")
        || lower.contains("authoritygrant")
        || lower.contains("secret")
        || lower.contains("token")
        || lower.contains("credential")
        || lower.contains("password")
        || lower.contains("raw")
        || lower.contains("command")
        || lower == "cmd"
        || lower.contains("stdout")
        || lower.contains("stderr")
        || lower == "log"
        || lower == "logs"
        || lower.contains("package")
        || lower.contains("environment")
        || lower == "env"
        || lower.contains("promptbody")
        || lower == "prompt"
        || lower == "content"
        || lower.contains("content")
        || lower == "body"
        || lower == "payload"
        || lower == "filecontents"
        || lower == "diff"
        || lower == "preview"
        || lower == "path"
        || lower.ends_with("path")
        || lower == "uri"
}

fn copy_key(target: &mut Map<String, Value>, source: &Value, key: &str) {
    if let Some(value) = source.get(key) {
        target.insert(key.to_owned(), bounded_model_context_value(value));
    }
}

fn bounded_model_context_value(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(truncate_model_context_string(text)),
        Value::Array(values) => Value::Array(
            values
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(bounded_model_context_value)
                .collect(),
        ),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, value)| (key.clone(), bounded_model_context_value(value)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn truncate_model_context_string(text: &str) -> String {
    let redacted = redact_model_context_string(text);
    if redacted.chars().count() <= MODEL_CONTEXT_STRING_MAX_CHARS {
        return redacted;
    }
    let mut truncated = redacted
        .chars()
        .take(MODEL_CONTEXT_STRING_MAX_CHARS)
        .collect::<String>();
    truncated.push_str("... [truncated]");
    truncated
}

fn redact_model_context_string(text: &str) -> String {
    static ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(/(?:Users|home|private|tmp|var|Volumes)/[^\s"',}\]]+)"#)
            .expect("valid absolute path redaction regex")
    });
    static UNSAFE_RELATIVE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(\.\.(?:/|\\)[^\s"',}\]]*)"#)
            .expect("valid relative path redaction regex")
    });

    let redacted = redact_sensitive_content(text);
    let redacted = ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
}

#[cfg(test)]
mod tests;
