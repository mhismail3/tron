use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use crate::domains::capability_support::implementations::capability_surface::{
    CapabilitySurfacePolicy, ResolvedCapabilitySurface,
};
use crate::domains::capability_support::implementations::traits::ExecutionMode;
use crate::shared::events::ActivatedRuleInfo;
use crate::shared::messages::{CapabilityResultMessageContent, Message};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};

use crate::domains::agent::runner::agent::capability_invocation_executor;
use crate::domains::agent::runner::agent::compaction_handler::CompactionHandler;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::orchestrator::event_persister::EventPersister;
use crate::domains::agent::runner::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::runner::types::{CapabilityInvocationExecutionResult, StreamResult};
use crate::domains::session::event_store::EventType;

use super::persistence;

pub(super) struct CapabilityInvocationPhaseParams<'a> {
    pub turn: u32,
    pub stream_result: &'a StreamResult,
    pub context_manager: &'a mut ContextManager,
    pub capability_surface: &'a ResolvedCapabilitySurface,
    pub capability_policy: &'a CapabilitySurfacePolicy,
    pub guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    pub hooks: &'a Option<Arc<HookEngine>>,
    pub compaction: &'a CompactionHandler,
    pub session_id: &'a str,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a CancellationToken,
    pub subagent_depth: u32,
    pub subagent_max_depth: u32,
    pub workspace_id: Option<&'a str>,
    pub persister: Option<&'a EventPersister>,
    /// Same persister as `persister`, but kept as a borrowed `Arc` so
    /// domain-owned capabilities can persist progress events. The dual surface
    /// avoids changing every existing `Option<&EventPersister>` signature upstream.
    pub persister_arc: Option<&'a Arc<EventPersister>>,
    pub process_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    pub job_manager: Option<
        &'a Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>,
    >,
    pub output_buffer_registry: Option<
        &'a Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub provider_type: crate::shared::messages::Provider,
    pub execution_spec: Option<&'a crate::shared::profile::AgentExecutionSpec>,
    pub profile_spec_hash: Option<&'a str>,
    /// Optional per-invocation abort registry (see `TurnParams::invocation_abort_registry`).
    pub invocation_abort_registry: Option<&'a Arc<InvocationAbortRegistry>>,
    /// Optional engine host used to route model-facing capability primitives.
    pub engine_host: Option<&'a crate::engine::EngineHostHandle>,
    /// Stable run id used for runtime capability-invocation idempotency.
    pub run_id: Option<&'a str>,
    pub trace_id: Option<&'a crate::engine::TraceId>,
    pub parent_invocation_id: Option<&'a crate::engine::InvocationId>,
}

#[derive(Default)]
pub(super) struct CapabilityInvocationPhaseOutcome {
    pub capability_invocations_executed: usize,
    pub stop_turn_requested: bool,
    pub activated_rules: Vec<ActivatedRuleInfo>,
}

fn target_identity_json(
    model_primitive_name: &str,
    capability_surface: &ResolvedCapabilitySurface,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
) -> Value {
    let Some(target) = capability_surface.targets_by_name.get(model_primitive_name) else {
        return json!({ "modelPrimitiveName": model_primitive_name });
    };
    let function = &target.function;
    let metadata_string = |key: &str| {
        function
            .metadata
            .get(key)
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    };
    let function_id = function.id.as_str().to_owned();
    json!({
        "modelPrimitiveName": model_primitive_name,
        "contractId": metadata_string("contractId")
            .or_else(|| metadata_string("capabilityContractId"))
            .unwrap_or_else(|| function_id.clone()),
        "implementationId": metadata_string("implementationId")
            .or_else(|| metadata_string("capabilityImplementationId"))
            .unwrap_or_else(|| format!("function:{function_id}")),
        "functionId": function_id,
        "pluginId": metadata_string("pluginId"),
        "workerId": function.owner_worker.as_str(),
        "catalogRevision": capability_surface.catalog_revision.0,
        "trustTier": metadata_string("trustTier"),
        "riskLevel": format!("{:?}", function.risk_level),
        "effectClass": format!("{:?}", function.effect_class),
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
    let Some(details) = result.result.details.as_ref() else {
        return Value::Object(identity);
    };
    if let Some(binding) = details.get("bindingDecision") {
        for (from, to) in [
            ("contractId", "contractId"),
            ("selectedImplementation", "implementationId"),
            ("selectedFunctionId", "functionId"),
            ("schemaDigest", "schemaDigest"),
            ("catalogRevision", "catalogRevision"),
            ("decisionId", "bindingDecisionId"),
        ] {
            if let Some(value) = binding.get(from) {
                identity.insert(to.to_owned(), value.clone());
            }
        }
    }
    for key in [
        "schemaDigest",
        "catalogRevision",
        "traceId",
        "rootInvocationId",
    ] {
        if let Some(value) = details.get(key) {
            identity.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(value) = details.get("selectedImplementation") {
        identity.insert("implementationId".to_owned(), value.clone());
    }
    if let Some(value) = details.get("functionId") {
        identity.insert("functionId".to_owned(), value.clone());
    }
    if let Some(plugin) = details
        .get("pluginVersions")
        .and_then(Value::as_array)
        .and_then(|plugins| plugins.first())
    {
        identity.insert("pluginId".to_owned(), plugin.clone());
    }
    identity.insert("modelPrimitiveName".to_owned(), json!(model_primitive_name));
    Value::Object(identity)
}

pub(super) async fn execute_capability_invocation_phase(
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    if params.stream_result.capability_invocations.is_empty() {
        return CapabilityInvocationPhaseOutcome::default();
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();

    // INVARIANT: persist capability.invocation.started events BEFORE broadcasting CapabilityInvocationBatch
    // so iOS subscribers cannot see a batch of capability invocations that are missing
    // from session history. Synchronous append surfaces any DB failure here
    // instead of deferring it to a background warning.
    let mut persist_failed = false;
    for capability_invocation in &params.stream_result.capability_invocations {
        if let Some(persister) = params.persister {
            let seq = params
                .sequence_counter
                .map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
            let mut payload = json!({
                "invocationId": capability_invocation.id,
                "name": capability_invocation.name,
                "arguments": capability_invocation.arguments,
                "turn": params.turn,
                "runId": params.run_id,
                "traceId": params.trace_id.map(|id| id.as_str()),
                "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
                "catalogRevision": params.capability_surface.catalog_revision.0,
            });
            if let (Some(payload), Some(identity)) = (
                payload.as_object_mut(),
                target_identity_json(
                    &capability_invocation.name,
                    params.capability_surface,
                    params.trace_id,
                    params.parent_invocation_id,
                )
                .as_object()
                .cloned(),
            ) {
                payload.extend(identity);
            }
            if let Err(error) = persister
                .append_with_sequence(
                    params.session_id,
                    EventType::CapabilityInvocationStarted,
                    payload,
                    seq,
                )
                .await
            {
                warn!(
                    params.session_id,
                    turn = params.turn,
                    invocation_id = %capability_invocation.id,
                    error = %error,
                    "failed to persist capability-invocation event; skipping broadcast + execution"
                );
                persist_failed = true;
                break;
            }
        }
    }

    if persist_failed {
        // Don't execute capabilities whose call events failed to persist; iOS
        // would see no history of them, and the agent would see results
        // for calls that don't exist. Surface the failure upward.
        return CapabilityInvocationPhaseOutcome::default();
    }

    persistence::emit_capability_invocation_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.capability_invocations,
        params.sequence_counter,
        params.trace_id,
        params.parent_invocation_id,
    );

    let waves = build_execution_waves(
        &params.stream_result.capability_invocations,
        params.capability_surface,
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
                let working_dir = &working_dir;
                let capability_ctx =
                    capability_invocation_executor::CapabilityInvocationExecutionContext {
                        capability_surface: params.capability_surface,
                        capability_policy: params.capability_policy,
                        guardrails: params.guardrails,
                        hooks: params.hooks,
                        emitter: params.emitter,
                        cancel: params.cancel,
                        subagent_depth: params.subagent_depth,
                        subagent_max_depth: params.subagent_max_depth,
                        workspace_id: params.workspace_id,
                        process_manager: params.process_manager,
                        job_manager: params.job_manager,
                        output_buffer_registry: params.output_buffer_registry,
                        sequence_counter: params.sequence_counter,
                        provider_type: params.provider_type,
                        execution_spec: params.execution_spec,
                        profile_spec_hash: params.profile_spec_hash,
                        event_persister: params.persister_arc,
                        turn: i64::from(params.turn),
                        invocation_abort_registry: params.invocation_abort_registry,
                        engine_host: params.engine_host,
                        run_id: params.run_id,
                        trace_id: params.trace_id,
                        parent_invocation_id: params.parent_invocation_id,
                    };
                async move {
                    let result = capability_invocation_executor::execute_capability_invocation(
                        capability_invocation,
                        params.session_id,
                        working_dir,
                        &capability_ctx,
                    )
                    .await;

                    // Persist capability.invocation.completed synchronously (await the DB write)
                    // so failures surface immediately and the agent sees a
                    // consistent history when it resumes after a crash. A
                    // background fire-and-forget here could silently drop
                    // the result under pressure or on DB error, leaving iOS
                    // with a live-stream CapabilityInvocationCompleted event that has no
                    // matching row in session history.
                    //
                    // The broadcast-vs-persist ordering (broadcast is
                    // inside capability_invocation_executor, persist is here) is not
                    // fully inverted — fully inverting would require
                    // plumbing the persister into capability_invocation_executor.
                    // Switching to sync persist makes the failure
                    // visible while keeping the change surgical.
                    if let Some(persister) = params.persister {
                        let result_text = extract_result_text(&result);
                        let is_error = result.result.is_error.unwrap_or(false);
                        let seq = params
                            .sequence_counter
                            .map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
                        let base_identity = target_identity_json(
                            &capability_invocation.name,
                            params.capability_surface,
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
                            "catalogRevision": params.capability_surface.catalog_revision.0,
                        });
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
                            .append_with_sequence(
                                params.session_id,
                                EventType::CapabilityInvocationCompleted,
                                payload,
                                seq,
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

    process_capability_results(results, &working_dir, params).await
}

async fn process_capability_results(
    mut results: Vec<Option<CapabilityInvocationExecutionResult>>,
    working_dir: &str,
    params: CapabilityInvocationPhaseParams<'_>,
) -> CapabilityInvocationPhaseOutcome {
    let mut outcome = CapabilityInvocationPhaseOutcome {
        activated_rules: Vec::with_capacity(8),
        ..Default::default()
    };

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

        let result_content = extract_result_content(&exec_result);
        let is_error = exec_result.result.is_error.unwrap_or(false);

        // capability.invocation.completed persistence is handled per-invocation inside the execution future
        // (before join_all) so the DB reflects completion immediately.

        // Add full content (including images) to LLM conversation context
        params
            .context_manager
            .add_message(Message::CapabilityResult {
                invocation_id: capability_invocation.id.clone(),
                content: result_content,
                is_error: if is_error { Some(true) } else { None },
            });

        let touched_paths =
            crate::domains::agent::runner::context::path_extractor::extract_touched_paths(
                &capability_invocation.name,
                &capability_invocation.arguments,
                std::path::Path::new(working_dir),
                std::path::Path::new(working_dir),
            );
        for path in &touched_paths {
            outcome
                .activated_rules
                .extend(params.context_manager.touch_file_path(path));
        }

        if capability_invocation.name == "execute"
            && matches!(
                capability_invocation
                    .arguments
                    .get("contractId")
                    .and_then(serde_json::Value::as_str),
                Some("process::run")
            )
            && let Some(command) = capability_invocation
                .arguments
                .get("payload")
                .and_then(serde_json::Value::as_object)
                .and_then(|payload| payload.get("command"))
                .and_then(serde_json::Value::as_str)
        {
            params.compaction.record_process_command(command);
        }

        if exec_result.stops_turn {
            outcome.stop_turn_requested = true;
        }
    }

    outcome
}

/// Build execution waves from capability invocations, respecting serialization groups.
///
/// - Parallel capabilities all go in wave 0
/// - Serialized capabilities in the same group spread across ascending waves
/// - Returns `Vec<Vec<usize>>` where each inner vec is indices into `capability_invocations`
pub(super) fn build_execution_waves(
    capability_invocations: &[crate::shared::messages::CapabilityInvocationDraft],
    capability_surface: &ResolvedCapabilitySurface,
) -> Vec<Vec<usize>> {
    let modes: Vec<_> = capability_invocations
        .iter()
        .map(|tc| {
            capability_surface
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

/// Extract text-only content from a capability result (for event persistence — no images in DB).
fn extract_result_text(exec_result: &CapabilityInvocationExecutionResult) -> String {
    match &exec_result.result.content {
        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => text.clone(),
        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                crate::shared::content::CapabilityResultContent::Text { text } => {
                    Some(text.as_str())
                }
                crate::shared::content::CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

/// Extract full content from a capability result, preserving image blocks for the LLM.
///
/// If no images are present, flattens to `Text` for efficiency.
/// When images exist, returns `Blocks` so the LLM can see them.
fn extract_result_content(
    exec_result: &CapabilityInvocationExecutionResult,
) -> CapabilityResultMessageContent {
    match &exec_result.result.content {
        crate::shared::model_capabilities::CapabilityResultBody::Text(text) => {
            CapabilityResultMessageContent::Text(text.clone())
        }
        crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
            let has_images = blocks.iter().any(|b| {
                matches!(
                    b,
                    crate::shared::content::CapabilityResultContent::Image { .. }
                )
            });
            if has_images {
                CapabilityResultMessageContent::Blocks(blocks.clone())
            } else {
                let text = blocks
                    .iter()
                    .filter_map(|b| match b {
                        crate::shared::content::CapabilityResultContent::Text { text } => {
                            Some(text.as_str())
                        }
                        crate::shared::content::CapabilityResultContent::Image { .. } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                CapabilityResultMessageContent::Text(text)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;
    use crate::shared::content::CapabilityResultContent;
    use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};

    fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
        CapabilityInvocationExecutionResult {
            invocation_id: "test".into(),
            result: CapabilityResult {
                content,
                details: None,
                is_error: None,
                stop_turn: None,
            },
            duration_ms: 100,
            blocked_by_hook: false,
            blocked_by_guardrail: false,
            is_interactive: false,
            stops_turn: false,
        }
    }

    // ── extract_result_content tests ──

    #[test]
    fn extract_result_content_text_body_passthrough() {
        let exec = make_exec_result(CapabilityResultBody::Text("hello".into()));
        let content = extract_result_content(&exec);
        assert!(matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "hello"));
    }

    #[test]
    fn extract_result_content_text_blocks_flatten() {
        let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::text("line 1"),
            CapabilityResultContent::text("line 2"),
        ]));
        let content = extract_result_content(&exec);
        assert!(
            matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "line 1\nline 2")
        );
    }

    #[test]
    fn extract_result_content_mixed_blocks_preserve() {
        let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::text("screenshot taken"),
            CapabilityResultContent::image("base64data", "image/png"),
        ]));
        let content = extract_result_content(&exec);
        match content {
            CapabilityResultMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2);
                assert!(
                    matches!(&blocks[0], CapabilityResultContent::Text { text } if text == "screenshot taken")
                );
                assert!(
                    matches!(&blocks[1], CapabilityResultContent::Image { data, mime_type } if data == "base64data" && mime_type == "image/png")
                );
            }
            CapabilityResultMessageContent::Text(_) => panic!("expected Blocks variant"),
        }
    }

    #[test]
    fn extract_result_content_image_only_blocks() {
        let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::image("imgdata", "image/jpeg"),
        ]));
        let content = extract_result_content(&exec);
        match content {
            CapabilityResultMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 1);
                assert!(matches!(&blocks[0], CapabilityResultContent::Image { .. }));
            }
            CapabilityResultMessageContent::Text(_) => panic!("expected Blocks variant"),
        }
    }

    // ── extract_result_text regression tests ──

    #[test]
    fn extract_result_text_drops_images() {
        let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::text("captured"),
            CapabilityResultContent::image("base64data", "image/png"),
        ]));
        let text = extract_result_text(&exec);
        assert_eq!(text, "captured");
        assert!(!text.contains("base64"));
    }

    #[test]
    fn extract_result_text_joins_text_blocks() {
        let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
            CapabilityResultContent::text("a"),
            CapabilityResultContent::text("b"),
        ]));
        assert_eq!(extract_result_text(&exec), "a\nb");
    }

    #[test]
    fn extract_result_text_body_passthrough() {
        let exec = make_exec_result(CapabilityResultBody::Text("plain".into()));
        assert_eq!(extract_result_text(&exec), "plain");
    }
}
