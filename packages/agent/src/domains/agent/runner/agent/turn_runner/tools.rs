use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use crate::domains::capability_support::implementations::capability_surface::{
    CapabilitySurfacePolicy, ResolvedToolSurface,
};
use crate::domains::capability_support::implementations::traits::ExecutionMode;
use crate::shared::events::ActivatedRuleInfo;
use crate::shared::messages::{Message, ToolResultMessageContent};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};

use crate::domains::agent::runner::agent::compaction_handler::CompactionHandler;
use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::agent::tool_executor;
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::guardrails::GuardrailEngine;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::orchestrator::event_persister::EventPersister;
use crate::domains::agent::runner::orchestrator::tool_abort_registry::ToolAbortRegistry;
use crate::domains::agent::runner::types::{StreamResult, ToolExecutionResult};
use crate::domains::session::event_store::EventType;

use super::persistence;

pub(super) struct ToolPhaseParams<'a> {
    pub turn: u32,
    pub stream_result: &'a StreamResult,
    pub context_manager: &'a mut ContextManager,
    pub tool_surface: &'a ResolvedToolSurface,
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
    /// Optional per-tool abort registry (see `TurnParams::tool_abort_registry`).
    pub tool_abort_registry: Option<&'a Arc<ToolAbortRegistry>>,
    /// Optional engine host used to route model-facing capability primitives.
    pub engine_host: Option<&'a crate::engine::EngineHostHandle>,
    /// Stable run id used for runtime capability-invocation idempotency.
    pub run_id: Option<&'a str>,
    pub trace_id: Option<&'a crate::engine::TraceId>,
    pub parent_invocation_id: Option<&'a crate::engine::InvocationId>,
}

#[derive(Default)]
pub(super) struct ToolPhaseOutcome {
    pub tool_calls_executed: usize,
    pub stop_turn_requested: bool,
    pub activated_rules: Vec<ActivatedRuleInfo>,
}

fn target_identity_json(
    tool_name: &str,
    tool_surface: &ResolvedToolSurface,
    trace_id: Option<&crate::engine::TraceId>,
    parent_invocation_id: Option<&crate::engine::InvocationId>,
) -> Value {
    let Some(target) = tool_surface.targets_by_name.get(tool_name) else {
        return json!({ "modelToolName": tool_name });
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
        "modelToolName": tool_name,
        "contractId": metadata_string("contractId")
            .or_else(|| metadata_string("capabilityContractId"))
            .unwrap_or_else(|| function_id.clone()),
        "implementationId": metadata_string("implementationId")
            .or_else(|| metadata_string("capabilityImplementationId"))
            .unwrap_or_else(|| format!("function:{function_id}")),
        "functionId": function_id,
        "pluginId": metadata_string("pluginId"),
        "workerId": function.owner_worker.as_str(),
        "catalogRevision": tool_surface.catalog_revision.0,
        "trustTier": metadata_string("trustTier"),
        "riskLevel": format!("{:?}", function.risk_level),
        "effectClass": format!("{:?}", function.effect_class),
        "traceId": trace_id.map(|id| id.as_str()),
        "rootInvocationId": parent_invocation_id.map(|id| id.as_str()),
    })
}

fn result_identity_json(
    tool_name: &str,
    base_identity: Value,
    result: &ToolExecutionResult,
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
    identity.insert("modelToolName".to_owned(), json!(tool_name));
    Value::Object(identity)
}

pub(super) async fn execute_tool_phase(params: ToolPhaseParams<'_>) -> ToolPhaseOutcome {
    if params.stream_result.tool_calls.is_empty() {
        return ToolPhaseOutcome::default();
    }

    let working_dir = params.context_manager.get_working_directory().to_owned();

    // INVARIANT: persist capability.invocation.started events BEFORE broadcasting CapabilityInvocationBatch
    // so iOS subscribers cannot see a batch of capability invocations that are missing
    // from session history. Synchronous append surfaces any DB failure here
    // instead of deferring it to a background warning.
    let mut persist_failed = false;
    for tool_call in &params.stream_result.tool_calls {
        if let Some(persister) = params.persister {
            let seq = params
                .sequence_counter
                .map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
            let mut payload = json!({
                "toolCallId": tool_call.id,
                "name": tool_call.name,
                "arguments": tool_call.arguments,
                "turn": params.turn,
                "runId": params.run_id,
                "traceId": params.trace_id.map(|id| id.as_str()),
                "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
                "toolCatalogRevision": params.tool_surface.catalog_revision.0,
            });
            if let (Some(payload), Some(identity)) = (
                payload.as_object_mut(),
                target_identity_json(
                    &tool_call.name,
                    params.tool_surface,
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
                    tool_call_id = %tool_call.id,
                    error = %error,
                    "failed to persist capability-invocation event; skipping broadcast + execution"
                );
                persist_failed = true;
                break;
            }
        }
    }

    if persist_failed {
        // Don't execute tools whose call events failed to persist; iOS
        // would see no history of them, and the agent would see results
        // for calls that don't exist. Surface the failure upward.
        return ToolPhaseOutcome::default();
    }

    persistence::emit_capability_invocation_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.tool_calls,
        params.sequence_counter,
        params.trace_id,
        params.parent_invocation_id,
    );

    let waves = build_execution_waves(&params.stream_result.tool_calls, params.tool_surface);
    let mut results: Vec<Option<ToolExecutionResult>> =
        vec![None; params.stream_result.tool_calls.len()];

    for wave in &waves {
        if params.cancel.is_cancelled() {
            break;
        }

        let futures: Vec<_> = wave
            .iter()
            .map(|&idx| {
                let tool_call = &params.stream_result.tool_calls[idx];
                let working_dir = &working_dir;
                let tool_ctx = tool_executor::ToolExecutionContext {
                    tool_surface: params.tool_surface,
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
                    tool_abort_registry: params.tool_abort_registry,
                    engine_host: params.engine_host,
                    run_id: params.run_id,
                    trace_id: params.trace_id,
                    parent_invocation_id: params.parent_invocation_id,
                };
                async move {
                    let result = tool_executor::execute_tool(
                        tool_call,
                        params.session_id,
                        working_dir,
                        &tool_ctx,
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
                    // inside tool_executor, persist is here) is not
                    // fully inverted — fully inverting would require
                    // plumbing the persister into tool_executor.
                    // Switching to sync persist makes the failure
                    // visible while keeping the change surgical.
                    if let Some(persister) = params.persister {
                        let result_text = extract_result_text(&result);
                        let is_error = result.result.is_error.unwrap_or(false);
                        let seq = params
                            .sequence_counter
                            .map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
                        let base_identity = target_identity_json(
                            &tool_call.name,
                            params.tool_surface,
                            params.trace_id,
                            params.parent_invocation_id,
                        );
                        let mut payload = json!({
                            "toolCallId": tool_call.id,
                            "name": tool_call.name,
                            "content": result_text,
                            "isError": is_error,
                            "duration": result.duration_ms,
                            "details": result.result.details,
                            "runId": params.run_id,
                            "traceId": params.trace_id.map(|id| id.as_str()),
                            "parentInvocationId": params.parent_invocation_id.map(|id| id.as_str()),
                            "toolCatalogRevision": params.tool_surface.catalog_revision.0,
                        });
                        if let (Some(payload), Some(identity)) = (
                            payload.as_object_mut(),
                            result_identity_json(&tool_call.name, base_identity, &result)
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
                                tool_call_id = %tool_call.id,
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

    process_tool_results(results, &working_dir, params).await
}

async fn process_tool_results(
    mut results: Vec<Option<ToolExecutionResult>>,
    working_dir: &str,
    params: ToolPhaseParams<'_>,
) -> ToolPhaseOutcome {
    let mut outcome = ToolPhaseOutcome {
        activated_rules: Vec::with_capacity(8),
        ..Default::default()
    };

    for (idx, tool_call) in params.stream_result.tool_calls.iter().enumerate() {
        let Some(exec_result) = results[idx].take() else {
            continue;
        };
        outcome.tool_calls_executed += 1;

        let result_content = extract_result_content(&exec_result);
        let is_error = exec_result.result.is_error.unwrap_or(false);

        // capability.invocation.completed persistence is handled per-tool inside the execution future
        // (before join_all) so the DB reflects completion immediately.

        // Add full content (including images) to LLM conversation context
        params.context_manager.add_message(Message::ToolResult {
            tool_call_id: tool_call.id.clone(),
            content: result_content,
            is_error: if is_error { Some(true) } else { None },
        });

        let touched_paths =
            crate::domains::agent::runner::context::path_extractor::extract_touched_paths(
                &tool_call.name,
                &tool_call.arguments,
                std::path::Path::new(working_dir),
                std::path::Path::new(working_dir),
            );
        for path in &touched_paths {
            outcome
                .activated_rules
                .extend(params.context_manager.touch_file_path(path));
        }

        if tool_call.name == "execute"
            && matches!(
                tool_call
                    .arguments
                    .get("contractId")
                    .and_then(serde_json::Value::as_str),
                Some("process::run")
            )
            && let Some(command) = tool_call
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
/// - Parallel tools all go in wave 0
/// - Serialized tools in the same group spread across ascending waves
/// - Returns `Vec<Vec<usize>>` where each inner vec is indices into `tool_calls`
pub(super) fn build_execution_waves(
    tool_calls: &[crate::shared::messages::ToolCall],
    tool_surface: &ResolvedToolSurface,
) -> Vec<Vec<usize>> {
    let modes: Vec<_> = tool_calls
        .iter()
        .map(|tc| {
            tool_surface
                .targets_by_name
                .get(&tc.name)
                .map_or(ExecutionMode::Parallel, |target| {
                    target.execution_mode.clone()
                })
        })
        .collect();

    if modes.iter().all(|m| matches!(m, ExecutionMode::Parallel)) {
        return vec![(0..tool_calls.len()).collect()];
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
fn extract_result_text(exec_result: &ToolExecutionResult) -> String {
    match &exec_result.result.content {
        crate::shared::tools::ToolResultBody::Text(text) => text.clone(),
        crate::shared::tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                crate::shared::content::ToolResultContent::Text { text } => Some(text.as_str()),
                crate::shared::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

/// Extract full content from a capability result, preserving image blocks for the LLM.
///
/// If no images are present, flattens to `Text` for efficiency.
/// When images exist, returns `Blocks` so the LLM can see them.
fn extract_result_content(exec_result: &ToolExecutionResult) -> ToolResultMessageContent {
    match &exec_result.result.content {
        crate::shared::tools::ToolResultBody::Text(text) => {
            ToolResultMessageContent::Text(text.clone())
        }
        crate::shared::tools::ToolResultBody::Blocks(blocks) => {
            let has_images = blocks
                .iter()
                .any(|b| matches!(b, crate::shared::content::ToolResultContent::Image { .. }));
            if has_images {
                ToolResultMessageContent::Blocks(blocks.clone())
            } else {
                let text = blocks
                    .iter()
                    .filter_map(|b| match b {
                        crate::shared::content::ToolResultContent::Text { text } => {
                            Some(text.as_str())
                        }
                        crate::shared::content::ToolResultContent::Image { .. } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                ToolResultMessageContent::Text(text)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::runner::types::ToolExecutionResult;
    use crate::shared::content::ToolResultContent;
    use crate::shared::tools::{CapabilityResult, ToolResultBody};

    fn make_exec_result(content: ToolResultBody) -> ToolExecutionResult {
        ToolExecutionResult {
            tool_call_id: "test".into(),
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
        let exec = make_exec_result(ToolResultBody::Text("hello".into()));
        let content = extract_result_content(&exec);
        assert!(matches!(content, ToolResultMessageContent::Text(ref t) if t == "hello"));
    }

    #[test]
    fn extract_result_content_text_blocks_flatten() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![
            ToolResultContent::text("line 1"),
            ToolResultContent::text("line 2"),
        ]));
        let content = extract_result_content(&exec);
        assert!(matches!(content, ToolResultMessageContent::Text(ref t) if t == "line 1\nline 2"));
    }

    #[test]
    fn extract_result_content_mixed_blocks_preserve() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![
            ToolResultContent::text("screenshot taken"),
            ToolResultContent::image("base64data", "image/png"),
        ]));
        let content = extract_result_content(&exec);
        match content {
            ToolResultMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 2);
                assert!(
                    matches!(&blocks[0], ToolResultContent::Text { text } if text == "screenshot taken")
                );
                assert!(
                    matches!(&blocks[1], ToolResultContent::Image { data, mime_type } if data == "base64data" && mime_type == "image/png")
                );
            }
            ToolResultMessageContent::Text(_) => panic!("expected Blocks variant"),
        }
    }

    #[test]
    fn extract_result_content_image_only_blocks() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![ToolResultContent::image(
            "imgdata",
            "image/jpeg",
        )]));
        let content = extract_result_content(&exec);
        match content {
            ToolResultMessageContent::Blocks(blocks) => {
                assert_eq!(blocks.len(), 1);
                assert!(matches!(&blocks[0], ToolResultContent::Image { .. }));
            }
            ToolResultMessageContent::Text(_) => panic!("expected Blocks variant"),
        }
    }

    // ── extract_result_text regression tests ──

    #[test]
    fn extract_result_text_drops_images() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![
            ToolResultContent::text("captured"),
            ToolResultContent::image("base64data", "image/png"),
        ]));
        let text = extract_result_text(&exec);
        assert_eq!(text, "captured");
        assert!(!text.contains("base64"));
    }

    #[test]
    fn extract_result_text_joins_text_blocks() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![
            ToolResultContent::text("a"),
            ToolResultContent::text("b"),
        ]));
        assert_eq!(extract_result_text(&exec), "a\nb");
    }

    #[test]
    fn extract_result_text_body_passthrough() {
        let exec = make_exec_result(ToolResultBody::Text("plain".into()));
        assert_eq!(extract_result_text(&exec), "plain");
    }
}
