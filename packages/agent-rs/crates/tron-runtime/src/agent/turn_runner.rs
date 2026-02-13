//! Turn runner — orchestrates a single turn: context → stream → tools → events.

use std::sync::Arc;
use std::time::Instant;

use tron_context::context_manager::ContextManager;
use tron_core::events::{
    BaseEvent, CompactionReason, ResponseTokenUsage, ToolCallSummary, TronEvent, TurnTokenUsage,
};
use tron_core::messages::{Message, ToolResultMessageContent};
use tron_guardrails::GuardrailEngine;
use tron_hooks::engine::HookEngine;
use tron_llm::provider::{Provider, ProviderStreamOptions};
use tron_tools::registry::ToolRegistry;

use crate::agent::compaction_handler::CompactionHandler;
use crate::agent::event_emitter::EventEmitter;
use crate::agent::stream_processor;
use crate::agent::tool_executor;
use crate::errors::StopReason;
use crate::types::{RunContext, TurnResult};

/// Execute a single turn of the agent loop.
#[allow(clippy::too_many_arguments, clippy::too_many_lines, clippy::cast_possible_truncation)]
pub async fn execute_turn(
    turn: u32,
    context_manager: &mut ContextManager,
    provider: &Arc<dyn Provider>,
    registry: &ToolRegistry,
    guardrails: &Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
    hooks: &Option<Arc<HookEngine>>,
    compaction: &CompactionHandler,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &tokio_util::sync::CancellationToken,
    run_context: &RunContext,
) -> TurnResult {
    let turn_start = Instant::now();

    // 1. Check context capacity (compact if needed)
    if let Err(e) = compaction
        .check_and_compact(
            context_manager,
            hooks,
            session_id,
            emitter,
            CompactionReason::PreTurnGuardrail,
        )
        .await
    {
        return TurnResult {
            success: false,
            error: Some(format!("Compaction error: {e}")),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
    }

    // 2. Emit TurnStart
    emitter.emit(TronEvent::TurnStart {
        base: BaseEvent::now(session_id),
        turn,
    });

    // 3. Build context
    let messages = context_manager.get_messages();
    let context = tron_core::messages::Context {
        system_prompt: Some(context_manager.get_system_prompt().to_owned()),
        messages,
        tools: Some(registry.definitions()),
        working_directory: Some(
            context_manager
                .get_model()
                .to_owned(),
        ),
        rules_content: context_manager.get_rules_content().map(String::from),
        memory_content: context_manager.get_full_memory_content(),
        skill_context: run_context.skill_context.clone(),
        subagent_results_context: run_context.subagent_results.clone(),
        task_context: run_context.task_context.clone(),
        dynamic_rules_context: run_context
            .dynamic_rules_context
            .clone()
            .or_else(|| context_manager.get_dynamic_rules_content().map(String::from)),
    };

    // 4. Build stream options
    let stream_options = ProviderStreamOptions {
        effort_level: run_context
            .reasoning_level
            .as_ref()
            .map(|r| r.as_effort_str().to_owned()),
        ..Default::default()
    };

    // 5. Stream from Provider
    let stream = match provider.stream(&context, &stream_options).await {
        Ok(s) => s,
        Err(e) => {
            let error_msg = e.to_string();
            let category = e.category().to_owned();
            let recoverable = e.is_retryable();

            emitter.emit(TronEvent::TurnFailed {
                base: BaseEvent::now(session_id),
                turn,
                error: error_msg.clone(),
                code: None,
                category: Some(category),
                recoverable,
                partial_content: None,
            });

            return TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
    };

    // 6. Process stream
    let stream_result =
        match stream_processor::process_stream(stream, session_id, emitter, cancel).await {
            Ok(r) => r,
            Err(e) => {
                let error_msg = e.to_string();
                emitter.emit(TronEvent::TurnFailed {
                    base: BaseEvent::now(session_id),
                    turn,
                    error: error_msg.clone(),
                    code: None,
                    category: Some(e.category().to_owned()),
                    recoverable: e.is_recoverable(),
                    partial_content: None,
                });
                return TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(StopReason::Error),
                    ..Default::default()
                };
            }
        };

    if stream_result.interrupted {
        return TurnResult {
            success: true,
            interrupted: true,
            partial_content: stream_result.partial_content,
            stop_reason: Some(StopReason::Interrupted),
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    // 7. Emit ResponseComplete (BEFORE tool execution)
    let response_token_usage = stream_result.token_usage.as_ref().map(|u| ResponseTokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
        cache_creation_5m_tokens: u.cache_creation_5m_tokens,
        cache_creation_1h_tokens: u.cache_creation_1h_tokens,
    });

    emitter.emit(TronEvent::ResponseComplete {
        base: BaseEvent::now(session_id),
        turn,
        stop_reason: stream_result.stop_reason.clone(),
        token_usage: response_token_usage,
        has_tool_calls: !stream_result.tool_calls.is_empty(),
        tool_call_count: stream_result.tool_calls.len() as u32,
    });

    // 8. Add assistant message to context
    let assistant_content = stream_result.message.content.clone();
    context_manager.add_message(Message::Assistant {
        content: assistant_content,
        usage: stream_result.token_usage.clone(),
        cost: None,
        stop_reason: None,
        thinking: None,
    });

    // Update API token count if available
    if let Some(ref usage) = stream_result.token_usage {
        context_manager.set_api_context_tokens(usage.input_tokens + usage.output_tokens);
    }

    // 9. Execute tool calls if present
    let mut tool_calls_executed = 0;
    let mut stop_turn_requested = false;

    if !stream_result.tool_calls.is_empty() {
        // Emit ToolUseBatch
        let summaries: Vec<ToolCallSummary> = stream_result
            .tool_calls
            .iter()
            .map(|tc| ToolCallSummary {
                id: tc.id.clone(),
                name: tc.name.clone(),
                arguments: tc.arguments.clone(),
            })
            .collect();

        emitter.emit(TronEvent::ToolUseBatch {
            base: BaseEvent::now(session_id),
            tool_calls: summaries,
        });

        let working_dir = context_manager
            .get_model()
            .to_owned();

        // Execute tools sequentially
        for tc in &stream_result.tool_calls {
            if cancel.is_cancelled() {
                break;
            }

            let exec_result = tool_executor::execute_tool(
                tc,
                registry,
                guardrails,
                hooks,
                session_id,
                &working_dir,
                emitter,
                cancel,
            )
            .await;

            tool_calls_executed += 1;

            // Add tool result message
            let result_text = match &exec_result.result.content {
                tron_core::tools::ToolResultBody::Text(t) => t.clone(),
                tron_core::tools::ToolResultBody::Blocks(blocks) => {
                    serde_json::to_string(blocks).unwrap_or_default()
                }
            };

            context_manager.add_message(Message::ToolResult {
                tool_call_id: tc.id.clone(),
                content: ToolResultMessageContent::Text(result_text),
                is_error: if exec_result.result.is_error.unwrap_or(false) {
                    Some(true)
                } else {
                    None
                },
            });

            if exec_result.stops_turn {
                stop_turn_requested = true;
                break;
            }
        }
    }

    // 10. Emit TurnEnd
    let duration = turn_start.elapsed().as_millis() as u64;
    let turn_token_usage = stream_result.token_usage.as_ref().map(|u| TurnTokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
    });

    emitter.emit(TronEvent::TurnEnd {
        base: BaseEvent::now(session_id),
        turn,
        duration,
        token_usage: turn_token_usage,
        token_record: None,
        cost: None,
        context_limit: Some(context_manager.get_context_limit()),
    });

    // Determine stop reason for this turn
    let stop_reason = if stop_turn_requested {
        Some(StopReason::ToolStop)
    } else if stream_result.tool_calls.is_empty() {
        // No tool calls → LLM is done
        if stream_result.stop_reason == "end_turn" {
            Some(StopReason::EndTurn)
        } else {
            Some(StopReason::NoToolCalls)
        }
    } else {
        // Has tool calls, not a stop-turn → continue looping
        None
    };

    TurnResult {
        success: true,
        error: None,
        tool_calls_executed,
        token_usage: stream_result.token_usage,
        stop_reason,
        interrupted: false,
        partial_content: None,
        stop_turn_requested,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Turn runner tests require mock Provider, which we test at the
    // TronAgent integration level. Here we verify TurnResult construction.

    #[test]
    fn turn_result_success() {
        let tr = TurnResult {
            success: true,
            tool_calls_executed: 2,
            stop_reason: Some(StopReason::EndTurn),
            ..Default::default()
        };
        assert!(tr.success);
        assert_eq!(tr.tool_calls_executed, 2);
        assert_eq!(tr.stop_reason, Some(StopReason::EndTurn));
    }

    #[test]
    fn turn_result_failure() {
        let tr = TurnResult {
            success: false,
            error: Some("timeout".into()),
            stop_reason: Some(StopReason::Error),
            ..Default::default()
        };
        assert!(!tr.success);
        assert_eq!(tr.error.as_deref(), Some("timeout"));
    }

    #[test]
    fn turn_result_interrupted() {
        let tr = TurnResult {
            success: true,
            interrupted: true,
            partial_content: Some("partial".into()),
            stop_reason: Some(StopReason::Interrupted),
            ..Default::default()
        };
        assert!(tr.interrupted);
        assert!(tr.partial_content.is_some());
    }

    #[test]
    fn turn_result_stop_turn() {
        let tr = TurnResult {
            success: true,
            stop_turn_requested: true,
            stop_reason: Some(StopReason::ToolStop),
            ..Default::default()
        };
        assert!(tr.stop_turn_requested);
    }
}
