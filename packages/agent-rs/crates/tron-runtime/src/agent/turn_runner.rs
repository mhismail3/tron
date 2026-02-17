//! Turn runner — orchestrates a single turn: context → stream → tools → events.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Instant;

use serde_json::json;
use tron_tools::traits::ExecutionMode;
use crate::context::context_manager::ContextManager;
use tron_core::content::AssistantContent;
use tron_core::events::{
    ActivatedRuleInfo, BaseEvent, CompactionReason, ResponseTokenUsage, ToolCallSummary,
    TronEvent, TurnTokenUsage,
};
use tron_core::messages::{Message, ToolResultMessageContent};
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use tron_llm::provider::{Provider, ProviderStreamOptions};
use tron_llm::{ProviderHealthTracker, StreamFactory, StreamRetryConfig, with_provider_retry};
use tron_tools::registry::ToolRegistry;

use metrics::{counter, histogram};
use tracing::{debug, error, info, instrument, warn};

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
    subagent_depth: u32,
    subagent_max_depth: u32,
    retry_config: Option<&tron_core::retry::RetryConfig>,
    health_tracker: Option<&Arc<ProviderHealthTracker>>,
) -> TurnResult {
    let turn_start = Instant::now();

    // 1. Check context capacity (compact if needed)
    match compaction
        .check_and_compact(
            context_manager,
            hooks,
            session_id,
            emitter,
            CompactionReason::PreTurnGuardrail,
        )
        .await
    {
        Err(e) => {
            return TurnResult {
                success: false,
                error: Some(format!("Compaction error: {e}")),
                stop_reason: Some(StopReason::Error),
                ..Default::default()
            };
        }
        Ok(true) => {
            context_manager.clear_dynamic_rules();
        }
        Ok(false) => {}
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
        reasoning_effort: run_context
            .reasoning_level
            .as_ref()
            .map(|r| r.as_openai_reasoning_effort().to_owned()),
        thinking_level: run_context
            .reasoning_level
            .as_ref()
            .map(|r| r.as_gemini_thinking_level().to_owned()),
        ..Default::default()
    };

    // 5. Stream from Provider (with retry if configured)
    let provider_name: &'static str = provider.provider_type().as_str();
    let model_name: String = provider.model().to_owned();
    counter!("provider_requests_total", "provider" => provider_name).increment(1);
    let request_start = Instant::now();

    let stream = if let Some(retry) = retry_config {
        // Wrap with retry — factory creates a new stream on each attempt
        let p = provider.clone();
        let ctx = context.clone();
        let opts = stream_options.clone();
        let factory: StreamFactory = Box::new(move || {
            let p = p.clone();
            let ctx = ctx.clone();
            let opts = opts.clone();
            Box::pin(async move { p.stream(&ctx, &opts).await })
        });
        let retry_cfg = StreamRetryConfig {
            retry: retry.clone(),
            emit_retry_events: true,
            cancel_token: Some(cancel.clone()),
        };
        with_provider_retry(factory, retry_cfg)
    } else {
        match provider.stream(&context, &stream_options).await {
            Ok(s) => s,
            Err(e) => {
                if let Some(ht) = health_tracker {
                    ht.record_failure(provider_name);
                }
                let error_msg = e.to_string();
                let category = e.category().to_owned();
                let recoverable = e.is_retryable();
                counter!("provider_errors_total", "provider" => provider_name, "status" => category.clone()).increment(1);
                histogram!("provider_request_duration_seconds", "provider" => provider_name)
                    .record(request_start.elapsed().as_secs_f64());
                warn!(
                    provider = %provider_name,
                    model = %provider.model(),
                    status = %category,
                    error = %e,
                    "provider stream error"
                );

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
        }
    };

    // 6. Process stream
    let stream_result =
        match stream_processor::process_stream(stream, session_id, emitter, cancel).await {
            Ok(r) => {
                if let Some(ht) = health_tracker {
                    ht.record_success(provider_name);
                }
                r
            }
            Err(e) => {
                if let Some(ht) = health_tracker {
                    ht.record_failure(provider_name);
                }
                histogram!("provider_request_duration_seconds", "provider" => provider_name)
                    .record(request_start.elapsed().as_secs_f64());
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

    // Record provider request duration (covers full stream consumption)
    histogram!("provider_request_duration_seconds", "provider" => provider_name)
        .record(request_start.elapsed().as_secs_f64());

    // Record time-to-first-token if available
    if let Some(ttft) = stream_result.ttft_ms {
        histogram!("provider_ttft_seconds", "provider" => provider_name)
            .record(ttft as f64 / 1000.0);
    }

    // Record LLM token counts
    if let Some(ref usage) = stream_result.token_usage {
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "input")
            .increment(usage.input_tokens);
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "output")
            .increment(usage.output_tokens);
    }

    if stream_result.interrupted {
        // Persist partial message.assistant so reconstruction shows streamed content
        if let Some(p) = persister {
            let content_json = persistence::build_content_json(&stream_result.message.content);
            if !content_json.is_empty() {
                let mut payload = json!({
                    "content": content_json,
                    "turn": turn,
                    "model": provider.model(),
                    "stopReason": "interrupted",
                    "interrupted": true,
                    "providerType": provider.provider_type().as_str(),
                });
                if let Some(ref usage) = stream_result.token_usage {
                    payload["tokenUsage"] = persistence::build_token_usage_json(usage);
                }
                if let Err(e) = p.append(session_id, EventType::MessageAssistant, payload).await {
                    tracing::error!(session_id, error = %e, "failed to persist interrupted message.assistant");
                }
            }
        }

        return TurnResult {
            success: true,
            interrupted: true,
            partial_content: stream_result.partial_content,
            stop_reason: Some(StopReason::Interrupted),
            token_usage: stream_result.token_usage,
            ..Default::default()
        };
    }

    // 7. Build token record + cost BEFORE ResponseComplete (iOS attaches stats from this)
    let token_record_json = stream_result.token_usage.as_ref().map(|usage| {
        persistence::build_token_record(
            usage,
            provider.provider_type(),
            session_id,
            turn,
            previous_context_baseline,
        )
    });

    let cost = stream_result
        .token_usage
        .as_ref()
        .map(|u| pricing::calculate_cost(provider.model(), u));

    // 7b. Emit ResponseComplete (BEFORE tool execution)
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
        token_record: token_record_json.clone(),
        model: Some(model_name.clone()),
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
        if let Err(e) = p.append(session_id, EventType::MessageAssistant, payload).await {
            tracing::error!(session_id, error = %e, "failed to persist message.assistant");
        }
    }

    // 9. Execute tool calls if present
    let mut tool_calls_executed = 0;
    let mut stop_turn_requested = false;
    let mut all_activations: Vec<ActivatedRuleInfo> = Vec::with_capacity(8);

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

        // --- Phase 1: Persist all tool.call events upfront ---
        for tc in &stream_result.tool_calls {
            if let Some(p) = persister {
                p.append_fire_and_forget(session_id, EventType::ToolCall, json!({
                    "toolCallId": tc.id,
                    "name": tc.name,
                    "arguments": tc.arguments,
                    "turn": turn,
                }));
            }
        }

        // --- Phase 2: Execute tools (parallel with serialization groups) ---
        let waves = build_execution_waves(&stream_result.tool_calls, registry);
        let mut results: Vec<Option<crate::types::ToolExecutionResult>> =
            vec![None; stream_result.tool_calls.len()];

        for wave in &waves {
            if cancel.is_cancelled() {
                break;
            }

            let futures: Vec<_> = wave
                .iter()
                .map(|&idx| {
                    let tc = &stream_result.tool_calls[idx];
                    let registry = &registry;
                    let guardrails = &guardrails;
                    let hooks = &hooks;
                    let working_dir = &working_dir;
                    let emitter = &emitter;
                    let cancel = &cancel;
                    async move {
                        let result = tool_executor::execute_tool(
                            tc,
                            registry,
                            guardrails,
                            hooks,
                            session_id,
                            working_dir,
                            emitter,
                            cancel,
                            subagent_depth,
                            subagent_max_depth,
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

        // --- Phase 3: Process results in original order ---
        for (i, tc) in stream_result.tool_calls.iter().enumerate() {
            let Some(exec_result) = results[i].take() else {
                continue;
            };
            tool_calls_executed += 1;

            let result_text = extract_result_text(&exec_result);
            let is_error = exec_result.result.is_error.unwrap_or(false);

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

            // Extract file paths from tool call and activate matching scoped rules
            let touched = crate::context::path_extractor::extract_touched_paths(
                &tc.name,
                &tc.arguments,
                std::path::Path::new(&working_dir),
                std::path::Path::new(&working_dir),
            );
            for path in &touched {
                let new_acts = context_manager.touch_file_path(path);
                all_activations.extend(new_acts);
            }

            if exec_result.stops_turn {
                stop_turn_requested = true;
            }
        }
    }

    // 9b. Emit batched rules.activated if any new rules were activated this turn
    if !all_activations.is_empty() {
        let total = context_manager.rules_tracker().activated_scoped_rules_count() as u32;
        let _ = emitter.emit(TronEvent::RulesActivated {
            base: BaseEvent::now(session_id),
            rules: all_activations.clone(),
            total_activated: total,
        });
        if let Some(p) = persister {
            p.append_fire_and_forget(
                session_id,
                EventType::RulesActivated,
                json!({
                    "rules": all_activations.iter().map(|a| json!({
                        "relativePath": a.relative_path,
                        "scopeDir": a.scope_dir,
                    })).collect::<Vec<_>>(),
                    "totalActivated": total,
                }),
            );
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
        model: Some(model_name.clone()),
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

    // Record turn metrics
    counter!("agent_turns_total", "model" => model_name.clone()).increment(1);
    histogram!("agent_turn_duration_seconds", "model" => model_name.clone())
        .record(turn_start.elapsed().as_secs_f64());

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
        model: Some(model_name),
        latency_ms: duration,
        has_thinking,
        llm_stop_reason: Some(stream_result.stop_reason.clone()),
        context_window_tokens,
        ..Default::default()
    }
}

/// Build execution waves from tool calls, respecting serialization groups.
///
/// - Parallel tools all go in wave 0
/// - Serialized tools in the same group spread across ascending waves
/// - Returns `Vec<Vec<usize>>` where each inner vec is indices into `tool_calls`
fn build_execution_waves(
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

    // Fast path: all parallel → single wave
    if modes
        .iter()
        .all(|m| matches!(m, ExecutionMode::Parallel))
    {
        return vec![(0..tool_calls.len()).collect()];
    }

    let mut waves: Vec<Vec<usize>> = Vec::with_capacity(4);
    waves.push(Vec::new());
    let mut group_wave: HashMap<String, usize> = HashMap::new();

    for (i, mode) in modes.iter().enumerate() {
        match mode {
            ExecutionMode::Parallel => waves[0].push(i),
            ExecutionMode::Serialized(group) => {
                let wave_idx = group_wave.get(group).copied().unwrap_or(0);
                while waves.len() <= wave_idx {
                    waves.push(vec![]);
                }
                waves[wave_idx].push(i);
                let _ = group_wave.insert(group.clone(), wave_idx + 1);
            }
        }
    }

    waves.retain(|w| !w.is_empty());
    waves
}

/// Extract plain text from a tool execution result.
fn extract_result_text(exec_result: &crate::types::ToolExecutionResult) -> String {
    match &exec_result.result.content {
        tron_core::tools::ToolResultBody::Text(t) => t.clone(),
        tron_core::tools::ToolResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                tron_core::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
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

    // ── build_execution_waves unit tests ──

    use serde_json::Map;
    use tron_core::messages::ToolCall;

    fn tc(name: &str) -> ToolCall {
        ToolCall {
            content_type: "tool_use".into(),
            id: format!("tc-{name}"),
            name: name.into(),
            arguments: Map::new(),
            thought_signature: None,
        }
    }

    /// Stub tool for wave builder tests — always Parallel.
    struct ParallelStub(&'static str);
    #[async_trait::async_trait]
    impl tron_tools::traits::TronTool for ParallelStub {
        fn name(&self) -> &str { self.0 }
        fn category(&self) -> tron_core::tools::ToolCategory { tron_core::tools::ToolCategory::Custom }
        fn definition(&self) -> tron_core::tools::Tool {
            tron_core::tools::Tool {
                name: self.0.into(),
                description: String::new(),
                parameters: tron_core::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None, required: None, description: None,
                    extra: Map::new(),
                },
            }
        }
        async fn execute(&self, _: serde_json::Value, _: &tron_tools::traits::ToolContext) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
            Ok(tron_core::tools::text_result("ok", false))
        }
    }

    /// Stub tool that returns Serialized(group).
    struct SerializedStub { name: &'static str, group: &'static str }
    #[async_trait::async_trait]
    impl tron_tools::traits::TronTool for SerializedStub {
        fn name(&self) -> &str { self.name }
        fn category(&self) -> tron_core::tools::ToolCategory { tron_core::tools::ToolCategory::Custom }
        fn execution_mode(&self) -> ExecutionMode { ExecutionMode::Serialized(self.group.into()) }
        fn definition(&self) -> tron_core::tools::Tool {
            tron_core::tools::Tool {
                name: self.name.into(),
                description: String::new(),
                parameters: tron_core::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None, required: None, description: None,
                    extra: Map::new(),
                },
            }
        }
        async fn execute(&self, _: serde_json::Value, _: &tron_tools::traits::ToolContext) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
            Ok(tron_core::tools::text_result("ok", false))
        }
    }

    fn wave_registry(tools: Vec<Arc<dyn tron_tools::traits::TronTool>>) -> ToolRegistry {
        let mut reg = ToolRegistry::new();
        for t in tools { reg.register(t); }
        reg
    }

    #[test]
    fn build_execution_waves_all_parallel() {
        let reg = wave_registry(vec![
            Arc::new(ParallelStub("read")),
            Arc::new(ParallelStub("write")),
            Arc::new(ParallelStub("grep")),
        ]);
        let calls = vec![tc("read"), tc("write"), tc("grep")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0, 1, 2]);
    }

    #[test]
    fn build_execution_waves_mixed() {
        // [Read(parallel), Browse₁(serialized:browser), Read(parallel), Browse₂(serialized:browser)]
        let reg = wave_registry(vec![
            Arc::new(ParallelStub("read")),
            Arc::new(SerializedStub { name: "browse", group: "browser" }),
        ]);
        let calls = vec![tc("read"), tc("browse"), tc("read"), tc("browse")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 2);
        assert_eq!(waves[0], vec![0, 1, 2]); // parallel + first browser
        assert_eq!(waves[1], vec![3]);        // second browser
    }

    #[test]
    fn build_execution_waves_multiple_groups() {
        // [Browse₁(browser), Bash₁(shell), Browse₂(browser), Bash₂(shell)]
        let reg = wave_registry(vec![
            Arc::new(SerializedStub { name: "browse", group: "browser" }),
            Arc::new(SerializedStub { name: "bash", group: "shell" }),
        ]);
        let calls = vec![tc("browse"), tc("bash"), tc("browse"), tc("bash")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 2);
        assert_eq!(waves[0], vec![0, 1]); // first of each group
        assert_eq!(waves[1], vec![2, 3]); // second of each group
    }

    #[test]
    fn build_execution_waves_single_tool() {
        let reg = wave_registry(vec![Arc::new(ParallelStub("read"))]);
        let calls = vec![tc("read")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0]);
    }

    #[test]
    fn build_execution_waves_unknown_tool_defaults_parallel() {
        let reg = ToolRegistry::new(); // empty — no tools registered
        let calls = vec![tc("unknown1"), tc("unknown2")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0, 1]);
    }

    #[test]
    fn build_execution_waves_only_serialized() {
        let reg = wave_registry(vec![
            Arc::new(SerializedStub { name: "browse", group: "browser" }),
        ]);
        let calls = vec![tc("browse"), tc("browse"), tc("browse")];
        let waves = build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 3);
        assert_eq!(waves[0], vec![0]);
        assert_eq!(waves[1], vec![1]);
        assert_eq!(waves[2], vec![2]);
    }
}
