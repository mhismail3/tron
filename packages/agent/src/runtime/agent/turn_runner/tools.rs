use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use serde_json::json;
use tokio_util::sync::CancellationToken;
use tracing::{error, warn};
use crate::core::events::ActivatedRuleInfo;
use crate::core::messages::{Message, ToolResultMessageContent};
use crate::tools::registry::ToolRegistry;
use crate::tools::traits::ExecutionMode;

use crate::runtime::agent::compaction_handler::CompactionHandler;
use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::agent::tool_executor;
use crate::runtime::context::context_manager::ContextManager;
use crate::runtime::guardrails::GuardrailEngine;
use crate::runtime::hooks::engine::HookEngine;
use crate::runtime::orchestrator::event_persister::EventPersister;
use crate::runtime::types::{StreamResult, ToolExecutionResult};
use crate::events::EventType;

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
    pub process_manager: Option<&'a Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub job_manager: Option<&'a Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub output_buffer_registry: Option<&'a Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub provider_type: crate::core::messages::Provider,
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

    let working_dir = params.context_manager.get_working_directory().to_owned();

    // INVARIANT: persist tool.call events BEFORE broadcasting ToolUseBatch
    // so iOS subscribers cannot see a batch of tool calls that are missing
    // from session history. Synchronous append surfaces any DB failure here
    // instead of deferring it to a background warning.
    let mut persist_failed = false;
    for tool_call in &params.stream_result.tool_calls {
        if let Some(persister) = params.persister {
            let seq = params.sequence_counter.map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
            if let Err(error) = persister
                .append_with_sequence(
                    params.session_id,
                    EventType::ToolCall,
                    json!({
                        "toolCallId": tool_call.id,
                        "name": tool_call.name,
                        "arguments": tool_call.arguments,
                        "turn": params.turn,
                    }),
                    seq,
                )
                .await
            {
                warn!(
                    params.session_id,
                    turn = params.turn,
                    tool_call_id = %tool_call.id,
                    error = %error,
                    "failed to persist tool-call event; skipping broadcast + execution"
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

    persistence::emit_tool_use_batch(
        params.emitter,
        params.session_id,
        &params.stream_result.tool_calls,
        params.sequence_counter,
    );

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
                    process_manager: params.process_manager,
                    job_manager: params.job_manager,
                    output_buffer_registry: params.output_buffer_registry,
                    sequence_counter: params.sequence_counter,
                    provider_type: params.provider_type,
                };
                async move {
                    let result = tool_executor::execute_tool(
                        tool_call,
                        params.session_id,
                        working_dir,
                        &tool_ctx,
                    )
                    .await;

                    // Persist tool.result synchronously (await the DB write)
                    // so failures surface immediately and the agent sees a
                    // consistent history when it resumes after a crash. A
                    // background fire-and-forget here could silently drop
                    // the result under pressure or on DB error, leaving iOS
                    // with a live-stream ToolExecutionEnd event that has no
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
                        let seq = params.sequence_counter.map(|c| c.fetch_add(1, Ordering::SeqCst) + 1);
                        if let Err(error) = persister
                            .append_with_sequence(
                                params.session_id,
                                EventType::ToolResult,
                                json!({
                                    "toolCallId": tool_call.id,
                                    "name": tool_call.name,
                                    "content": result_text,
                                    "isError": is_error,
                                    "duration": result.duration_ms,
                                    "details": result.result.details,
                                }),
                                seq,
                            )
                            .await
                        {
                            error!(
                                params.session_id,
                                turn = params.turn,
                                tool_call_id = %tool_call.id,
                                error = %error,
                                "failed to persist tool-result event"
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

        // tool.result persistence is handled per-tool inside the execution future
        // (before join_all) so the DB reflects completion immediately.

        // Add full content (including images) to LLM conversation context
        params.context_manager.add_message(Message::ToolResult {
            tool_call_id: tool_call.id.clone(),
            content: result_content,
            is_error: if is_error { Some(true) } else { None },
        });

        let touched_paths = crate::runtime::context::path_extractor::extract_touched_paths(
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
    tool_calls: &[crate::core::messages::ToolCall],
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

/// Extract text-only content from a tool result (for event persistence — no images in DB).
fn extract_result_text(exec_result: &ToolExecutionResult) -> String {
    match &exec_result.result.content {
        crate::core::tools::ToolResultBody::Text(text) => text.clone(),
        crate::core::tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                crate::core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                crate::core::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

/// Extract full content from a tool result, preserving image blocks for the LLM.
///
/// If no images are present, flattens to `Text` for efficiency.
/// When images exist, returns `Blocks` so the LLM can see them.
fn extract_result_content(exec_result: &ToolExecutionResult) -> ToolResultMessageContent {
    match &exec_result.result.content {
        crate::core::tools::ToolResultBody::Text(text) => {
            ToolResultMessageContent::Text(text.clone())
        }
        crate::core::tools::ToolResultBody::Blocks(blocks) => {
            let has_images = blocks.iter().any(|b| {
                matches!(b, crate::core::content::ToolResultContent::Image { .. })
            });
            if has_images {
                ToolResultMessageContent::Blocks(blocks.clone())
            } else {
                let text = blocks
                    .iter()
                    .filter_map(|b| match b {
                        crate::core::content::ToolResultContent::Text { text } => {
                            Some(text.as_str())
                        }
                        crate::core::content::ToolResultContent::Image { .. } => None,
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
    use crate::core::content::ToolResultContent;
    use crate::core::tools::{ToolResultBody, TronToolResult};
    use crate::runtime::types::ToolExecutionResult;

    fn make_exec_result(content: ToolResultBody) -> ToolExecutionResult {
        ToolExecutionResult {
            tool_call_id: "test".into(),
            result: TronToolResult {
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
                assert!(matches!(&blocks[0], ToolResultContent::Text { text } if text == "screenshot taken"));
                assert!(matches!(&blocks[1], ToolResultContent::Image { data, mime_type } if data == "base64data" && mime_type == "image/png"));
            }
            ToolResultMessageContent::Text(_) => panic!("expected Blocks variant"),
        }
    }

    #[test]
    fn extract_result_content_image_only_blocks() {
        let exec = make_exec_result(ToolResultBody::Blocks(vec![
            ToolResultContent::image("imgdata", "image/jpeg"),
        ]));
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
