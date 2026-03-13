use std::collections::HashMap;
use std::sync::Arc;

use serde_json::json;
use tokio_util::sync::CancellationToken;
use tracing::warn;
use tron_core::events::ActivatedRuleInfo;
use tron_core::messages::{Message, ToolResultMessageContent};
use tron_tools::registry::ToolRegistry;
use tron_tools::traits::ExecutionMode;

use crate::agent::compaction_handler::CompactionHandler;
use crate::agent::event_emitter::EventEmitter;
use crate::agent::tool_executor;
use crate::context::context_manager::ContextManager;
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use crate::orchestrator::event_persister::EventPersister;
use crate::types::{StreamResult, ToolExecutionResult};
use tron_events::EventType;

use super::persistence;

pub(super) struct ToolPhaseParams<'a> {
    pub turn: u32,
    pub stream_result: &'a StreamResult,
    pub context_manager: &'a mut ContextManager,
    pub registry: &'a ToolRegistry,
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
}

#[derive(Default)]
pub(super) struct ToolPhaseOutcome {
    pub tool_calls_executed: usize,
    pub stop_turn_requested: bool,
    pub activated_rules: Vec<ActivatedRuleInfo>,
}

pub(super) async fn execute_tool_phase(params: ToolPhaseParams<'_>) -> ToolPhaseOutcome {
    if params.stream_result.tool_calls.is_empty() {
        return ToolPhaseOutcome::default();
    }

    persistence::emit_tool_use_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.tool_calls,
    );
    let working_dir = params.context_manager.get_working_directory().to_owned();

    for tool_call in &params.stream_result.tool_calls {
        if let Some(persister) = params.persister
            && let Err(error) = persister
                .append_background(
                    params.session_id,
                    EventType::ToolCall,
                    json!({
                        "toolCallId": tool_call.id,
                        "name": tool_call.name,
                        "arguments": tool_call.arguments,
                        "turn": params.turn,
                    }),
                )
                .await
        {
            warn!(
                params.session_id,
                turn = params.turn,
                tool_call_id = %tool_call.id,
                error = %error,
                "failed to queue tool-call event"
            );
        }
    }

    let waves = build_execution_waves(&params.stream_result.tool_calls, params.registry);
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
                    registry: params.registry,
                    guardrails: params.guardrails,
                    hooks: params.hooks,
                    emitter: params.emitter,
                    cancel: params.cancel,
                    subagent_depth: params.subagent_depth,
                    subagent_max_depth: params.subagent_max_depth,
                    workspace_id: params.workspace_id,
                };
                async move {
                    let result = tool_executor::execute_tool(
                        tool_call,
                        params.session_id,
                        working_dir,
                        &tool_ctx,
                    )
                    .await;
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

        let result_text = extract_result_text(&exec_result);
        let is_error = exec_result.result.is_error.unwrap_or(false);

        if let Some(persister) = params.persister
            && let Err(error) = persister
                .append_background(
                    params.session_id,
                    EventType::ToolResult,
                    json!({
                        "toolCallId": tool_call.id,
                        "name": tool_call.name,
                        "content": result_text,
                        "isError": is_error,
                        "duration": exec_result.duration_ms,
                    }),
                )
                .await
        {
            warn!(
                params.session_id,
                turn = params.turn,
                tool_call_id = %tool_call.id,
                error = %error,
                "failed to queue tool-result event"
            );
        }

        params.context_manager.add_message(Message::ToolResult {
            tool_call_id: tool_call.id.clone(),
            content: ToolResultMessageContent::Text(result_text),
            is_error: if is_error { Some(true) } else { None },
        });

        let touched_paths = crate::context::path_extractor::extract_touched_paths(
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

        if tool_call.name == "Bash"
            && let Some(command) = tool_call.arguments.get("command").and_then(|v| v.as_str())
        {
            params.compaction.record_bash_command(command);
        }

        if exec_result.stops_turn {
            outcome.stop_turn_requested = true;
        }
    }

    outcome
}

/// Build execution waves from tool calls, respecting serialization groups.
///
/// - Parallel tools all go in wave 0
/// - Serialized tools in the same group spread across ascending waves
/// - Returns `Vec<Vec<usize>>` where each inner vec is indices into `tool_calls`
pub(super) fn build_execution_waves(
    tool_calls: &[tron_core::messages::ToolCall],
    registry: &ToolRegistry,
) -> Vec<Vec<usize>> {
    let modes: Vec<_> = tool_calls
        .iter()
        .map(|tc| {
            registry
                .get(&tc.name)
                .map_or(ExecutionMode::Parallel, |t| t.execution_mode())
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

fn extract_result_text(exec_result: &ToolExecutionResult) -> String {
    match &exec_result.result.content {
        tron_core::tools::ToolResultBody::Text(text) => text.clone(),
        tron_core::tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                tron_core::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}
