//! Turn runner — orchestrates a single turn: context → stream → tools → events.

use std::sync::Arc;
use std::time::Instant;

use serde_json::json;
use tron_context::context_manager::ContextManager;
use tron_core::content::AssistantContent;
use tron_core::events::{
    BaseEvent, CompactionReason, ResponseTokenUsage, ToolCallSummary, TronEvent, TurnTokenUsage,
};
use tron_core::messages::{Message, ToolResultMessageContent};
use tron_guardrails::GuardrailEngine;
use tron_hooks::engine::HookEngine;
use tron_llm::provider::{Provider, ProviderStreamOptions};
use tron_tools::registry::ToolRegistry;

use tracing::{debug, error, info, instrument};

use crate::agent::compaction_handler::CompactionHandler;
use crate::agent::event_emitter::EventEmitter;
use crate::agent::stream_processor;
use crate::agent::tool_executor;
use tron_events::EventType;

use crate::errors::StopReason;
use crate::orchestrator::event_persister::EventPersister;
use crate::pipeline::{persistence, pricing};
use crate::types::{RunContext, TurnResult};

/// Execute a single turn of the agent loop.
#[allow(clippy::too_many_arguments, clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(session_id, turn, model = provider.model()))]
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
    persister: Option<&EventPersister>,
    previous_context_baseline: u64,
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

    // 2. Emit TurnStart and persist (TS persists stream.turn_start events)
    let _ = emitter.emit(TronEvent::TurnStart {
        base: BaseEvent::now(session_id),
        turn,
    });
    if let Some(p) = persister {
        p.append_fire_and_forget(session_id, EventType::StreamTurnStart, json!({
            "turn": turn,
        }));
    }
    debug!(session_id, turn, "turn started");

    // 3. Build context
    let messages = context_manager.get_messages();
    let context = tron_core::messages::Context {
        system_prompt: Some(context_manager.get_system_prompt().to_owned()),
        messages,
        tools: Some(registry.definitions()),
        working_directory: Some(
            context_manager
                .get_working_directory()
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

    // 4. Build stream options (thinking always enabled — provider handles model-specific config)
    let stream_options = ProviderStreamOptions {
        enable_thinking: Some(true),
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

            let _ = emitter.emit(TronEvent::TurnFailed {
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
                error!(session_id, turn, error = %error_msg, "stream failed");
                let _ = emitter.emit(TronEvent::TurnFailed {
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

    let _ = emitter.emit(TronEvent::ResponseComplete {
        base: BaseEvent::now(session_id),
        turn,
        stop_reason: stream_result.stop_reason.clone(),
        token_usage: response_token_usage,
        has_tool_calls: !stream_result.tool_calls.is_empty(),
        tool_call_count: stream_result.tool_calls.len() as u32,
    });

    // 8. Add assistant message to context — preserve metadata (fix: was None/None)
    let has_thinking = stream_result
        .message
        .content
        .iter()
        .any(|c| matches!(c, AssistantContent::Thinking { .. }));
    let thinking_text = stream_result
        .message
        .content
        .iter()
        .find_map(|c| {
            if let AssistantContent::Thinking { thinking, .. } = c {
                Some(thinking.clone())
            } else {
                None
            }
        });
    let stop_reason_for_context: Option<tron_core::messages::StopReason> =
        serde_json::from_value(serde_json::Value::String(
            stream_result.stop_reason.clone(),
        ))
        .ok();

    let assistant_content = stream_result.message.content.clone();
    context_manager.add_message(Message::Assistant {
        content: assistant_content,
        usage: stream_result.token_usage.clone(),
        cost: None,
        stop_reason: stop_reason_for_context,
        thinking: thinking_text,
    });

    // Update API token count if available
    if let Some(ref usage) = stream_result.token_usage {
        context_manager.set_api_context_tokens(usage.input_tokens + usage.output_tokens);
    }

    // 8b. Build token record once — reused for persistence AND TurnEnd event
    let token_record_json = stream_result.token_usage.as_ref().map(|usage| {
        persistence::build_token_record(
            usage,
            provider.provider_type(),
            session_id,
            turn,
            previous_context_baseline,
        )
    });

    // 8c. Calculate cost for this turn
    let cost = stream_result
        .token_usage
        .as_ref()
        .map(|u| pricing::calculate_cost(provider.model(), u));

    // 8d. Persist message.assistant inline
    if let Some(p) = persister {
        let content_json = persistence::build_content_json(&stream_result.message.content);
        let mut payload = json!({
            "content": content_json,
            "turn": turn,
            "model": provider.model(),
            "latency": turn_start.elapsed().as_millis() as u64,
            "stopReason": &stream_result.stop_reason,
            "hasThinking": has_thinking,
            "providerType": provider.provider_type().as_str(),
        });
        if let Some(ref usage) = stream_result.token_usage {
            payload["tokenUsage"] = persistence::build_token_usage_json(usage);
        }
        if let Some(ref record) = token_record_json {
            payload["tokenRecord"] = record.clone();
        }
        if let Some(c) = cost {
            payload["cost"] = json!(c);
        }
        p.append_fire_and_forget(session_id, EventType::MessageAssistant, payload);
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

        let _ = emitter.emit(TronEvent::ToolUseBatch {
            base: BaseEvent::now(session_id),
            tool_calls: summaries,
        });

        let working_dir = context_manager
            .get_working_directory()
            .to_owned();

        // Execute tools sequentially
        for tc in &stream_result.tool_calls {
            if cancel.is_cancelled() {
                break;
            }

            // Persist tool.call BEFORE execution
            if let Some(p) = persister {
                p.append_fire_and_forget(session_id, EventType::ToolCall, json!({
                    "toolCallId": tc.id,
                    "name": tc.name,
                    "arguments": tc.arguments,
                    "turn": turn,
                }));
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

            // Add tool result message — extract plain text from blocks (not JSON)
            let result_text = match &exec_result.result.content {
                tron_core::tools::ToolResultBody::Text(t) => t.clone(),
                tron_core::tools::ToolResultBody::Blocks(blocks) => {
                    blocks
                        .iter()
                        .filter_map(|b| {
                            if let tron_core::content::ToolResultContent::Text { text } = b {
                                Some(text.as_str())
                            } else {
                                None
                            }
                        })
                        .collect::<Vec<_>>()
                        .join("\n")
                }
            };

            let is_error = exec_result.result.is_error.unwrap_or(false);

            // Persist tool.result AFTER execution
            if let Some(p) = persister {
                p.append_fire_and_forget(session_id, EventType::ToolResult, json!({
                    "toolCallId": tc.id,
                    "name": tc.name,
                    "content": result_text,
                    "isError": is_error,
                    "duration": exec_result.duration_ms,
                }));
            }

            context_manager.add_message(Message::ToolResult {
                tool_call_id: tc.id.clone(),
                content: ToolResultMessageContent::Text(result_text),
                is_error: if is_error { Some(true) } else { None },
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

    let _ = emitter.emit(TronEvent::TurnEnd {
        base: BaseEvent::now(session_id),
        turn,
        duration,
        token_usage: turn_token_usage,
        token_record: token_record_json.clone(),
        cost,
        stop_reason: Some(stream_result.stop_reason.clone()),
        context_limit: Some(context_manager.get_context_limit()),
    });

    // Persist stream.turn_end for iOS reconstruction (turn tracking + tokenRecord)
    if let Some(p) = persister {
        let mut tu_obj = json!({
            "inputTokens": stream_result.token_usage.as_ref().map_or(0, |u| u.input_tokens),
            "outputTokens": stream_result.token_usage.as_ref().map_or(0, |u| u.output_tokens),
        });
        if let Some(ref usage) = stream_result.token_usage {
            if let Some(cr) = usage.cache_read_tokens {
                tu_obj["cacheReadTokens"] = json!(cr);
            }
            if let Some(cc) = usage.cache_creation_tokens {
                tu_obj["cacheCreationTokens"] = json!(cc);
            }
        }
        let mut turn_end_payload = json!({
            "turn": turn,
            "tokenUsage": tu_obj,
            "stopReason": &stream_result.stop_reason,
            "contextLimit": context_manager.get_context_limit(),
        });
        if let Some(ref record) = token_record_json {
            turn_end_payload["tokenRecord"] = record.clone();
        }
        if let Some(c) = cost {
            turn_end_payload["cost"] = json!(c);
        }
        p.append_fire_and_forget(session_id, EventType::StreamTurnEnd, turn_end_payload);
    }

    info!(
        session_id,
        turn,
        duration_ms = duration,
        model = provider.model(),
        stop_reason = %stream_result.stop_reason,
        tools = tool_calls_executed,
        has_thinking,
        "turn completed"
    );

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

    let context_window_tokens = token_record_json
        .as_ref()
        .and_then(|r| r["computed"]["contextWindowTokens"].as_u64());

    TurnResult {
        success: true,
        tool_calls_executed,
        token_usage: stream_result.token_usage,
        stop_reason,
        stop_turn_requested,
        model: Some(provider.model().to_owned()),
        latency_ms: duration,
        has_thinking,
        llm_stop_reason: Some(stream_result.stop_reason.clone()),
        context_window_tokens,
        ..Default::default()
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
