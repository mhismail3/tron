//! Turn runner — orchestrates a single turn: context → stream → tools → events.

mod persistence;
mod provider;
mod result;
mod tools;

use std::sync::Arc;
use std::time::Instant;

use crate::context::context_manager::ContextManager;
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use tron_core::events::{BaseEvent, CompactionReason, TronEvent};
use tron_core::messages::Context;
use tron_llm::ProviderHealthTracker;
use tron_llm::provider::Provider;
use tron_tools::registry::ToolRegistry;

use metrics::{counter, histogram};
use tracing::{debug, error, instrument, warn};

use self::persistence::{
    add_assistant_message_to_context, build_completed_assistant_payload,
    build_interrupted_message_payload, build_token_record_json, emit_response_complete,
    emit_turn_end, emit_turn_start, persist_completed_assistant_message,
    persist_interrupted_message, persist_rules_activated,
};
use self::provider::{build_stream_options, open_stream};
use self::result::determine_turn_stop_reason;
use self::tools::ToolPhaseParams;
use crate::agent::compaction_handler::CompactionHandler;
use crate::agent::event_emitter::EventEmitter;
use crate::agent::stream_processor;
use crate::errors::StopReason;
use crate::orchestrator::event_persister::EventPersister;
use crate::types::{RunContext, TurnResult};

/// Parameters for a single turn of the agent loop.
pub struct TurnParams<'a> {
    /// Current turn number (1-indexed).
    pub turn: u32,
    /// Context manager owning messages, rules, and token tracking.
    pub context_manager: &'a mut ContextManager,
    /// LLM provider for streaming.
    pub provider: &'a Arc<dyn Provider>,
    /// Tool registry for tool lookup and execution.
    pub registry: &'a ToolRegistry,
    /// Optional guardrail engine for tool argument validation.
    pub guardrails: &'a Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Optional hook engine for pre/post tool use hooks.
    pub hooks: &'a Option<Arc<HookEngine>>,
    /// Compaction handler for pre-turn context checks.
    pub compaction: &'a CompactionHandler,
    /// Session identifier.
    pub session_id: &'a str,
    /// Event emitter for broadcasting agent lifecycle events.
    pub emitter: &'a Arc<EventEmitter>,
    /// Cancellation token for aborting the turn.
    pub cancel: &'a tokio_util::sync::CancellationToken,
    /// Run-scoped context (skill, reasoning level, subagent results).
    pub run_context: &'a RunContext,
    /// Optional event persister for inline event storage.
    pub persister: Option<&'a EventPersister>,
    /// Previous turn's context window token count (for delta tracking).
    pub previous_context_baseline: u64,
    /// Current subagent nesting depth.
    pub subagent_depth: u32,
    /// Maximum allowed subagent nesting depth.
    pub subagent_max_depth: u32,
    /// Optional retry configuration for provider stream retries.
    pub retry_config: Option<&'a tron_core::retry::RetryConfig>,
    /// Optional provider health tracker for circuit-breaking.
    pub health_tracker: Option<&'a Arc<ProviderHealthTracker>>,
    /// Workspace ID for scoping tool context (e.g. memory recall).
    pub workspace_id: Option<&'a str>,
    /// Server origin (e.g. `"localhost:9847"`) for system prompt.
    pub server_origin: Option<&'a str>,
}

/// Execute a single turn of the agent loop.
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
#[instrument(skip_all, fields(session_id, turn, model = params.provider.model()))]
pub async fn execute_turn(params: TurnParams<'_>) -> TurnResult {
    let TurnParams {
        turn,
        context_manager,
        provider,
        registry,
        guardrails,
        hooks,
        compaction,
        session_id,
        emitter,
        cancel,
        run_context,
        persister,
        previous_context_baseline,
        subagent_depth,
        subagent_max_depth,
        retry_config,
        health_tracker,
        workspace_id,
        server_origin,
    } = params;
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
            counter!("compaction_total", "status" => "pre_turn_error").increment(1);
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
    emit_turn_start(emitter, persister, session_id, turn).await;
    debug!(session_id, turn, "turn started");

    // 3. Build context (base from CM, external fields from RunContext/params)
    let context = build_turn_context(context_manager, registry, run_context, server_origin);

    // 4. Build stream options (thinking always enabled — provider handles model-specific config)
    let stream_options = build_stream_options(run_context);

    // 5. Stream from Provider (with retry if configured)
    let provider_name: &'static str = provider.provider_type().as_str();
    let model_name: String = provider.model().to_owned();
    counter!("provider_requests_total", "provider" => provider_name).increment(1);
    let request_start = Instant::now();

    let stream = match open_stream(provider, context, stream_options, cancel, retry_config).await {
        Ok(stream) => stream,
        Err(error) => {
            if let Some(ht) = health_tracker {
                ht.record_failure(provider_name);
            }
            let error_msg = error.to_string();
            let category = error.category().to_owned();
            let recoverable = error.is_retryable();
            counter!("provider_errors_total", "provider" => provider_name, "status" => category.clone()).increment(1);
            histogram!("provider_request_duration_seconds", "provider" => provider_name)
                .record(request_start.elapsed().as_secs_f64());
            warn!(
                provider = %provider_name,
                model = %provider.model(),
                status = %category,
                error = %error,
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
        histogram!("provider_ttft_seconds", "provider" => provider_name).record({
            #[allow(clippy::cast_precision_loss)]
            let secs = ttft as f64 / 1000.0;
            secs
        });
    }

    // Record LLM token counts
    if let Some(ref usage) = stream_result.token_usage {
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "input")
            .increment(usage.input_tokens);
        counter!("llm_tokens_total", "provider" => provider_name, "direction" => "output")
            .increment(usage.output_tokens);
    }

    if stream_result.interrupted {
        persist_interrupted_message(
            persister,
            session_id,
            build_interrupted_message_payload(
                &stream_result.message,
                stream_result.token_usage.as_ref(),
                turn,
                provider.model(),
                provider.provider_type(),
            ),
        )
        .await;

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
    let (token_record_json, cost) = build_token_record_json(
        stream_result.token_usage.as_ref(),
        provider.provider_type(),
        session_id,
        turn,
        previous_context_baseline,
        provider.model(),
    );

    emit_response_complete(
        emitter,
        session_id,
        turn,
        &stream_result,
        token_record_json.clone(),
        &model_name,
    );

    let has_thinking = add_assistant_message_to_context(context_manager, &stream_result);

    persist_completed_assistant_message(
        persister,
        session_id,
        build_completed_assistant_payload(
            &stream_result,
            turn,
            provider.model(),
            turn_start.elapsed().as_millis() as u64,
            has_thinking,
            provider.provider_type(),
            token_record_json.as_ref(),
            cost,
        ),
    )
    .await;

    let tool_phase = tools::execute_tool_phase(ToolPhaseParams {
        turn,
        stream_result: &stream_result,
        context_manager,
        registry,
        guardrails,
        hooks,
        compaction,
        session_id,
        emitter,
        cancel,
        subagent_depth,
        subagent_max_depth,
        workspace_id,
        persister,
    })
    .await;

    // 9b. Emit batched rules.activated if any new rules were activated this turn
    if !tool_phase.activated_rules.is_empty() {
        let total = context_manager
            .rules_tracker()
            .activated_scoped_rules_count() as u32;
        let _ = emitter.emit(TronEvent::RulesActivated {
            base: BaseEvent::now(session_id),
            rules: tool_phase.activated_rules.clone(),
            total_activated: total,
        });
        persist_rules_activated(
            persister,
            session_id,
            turn,
            &tool_phase.activated_rules,
            total,
        )
        .await;
    }

    // 10. Emit TurnEnd
    let duration = turn_start.elapsed().as_millis() as u64;
    emit_turn_end(
        emitter,
        persister,
        session_id,
        turn,
        duration,
        &stream_result,
        token_record_json.clone(),
        cost,
        context_manager.get_context_limit(),
        &model_name,
    )
    .await;

    debug!(
        session_id,
        turn,
        duration_ms = duration,
        model = provider.model(),
        stop_reason = %stream_result.stop_reason,
        tools = tool_phase.tool_calls_executed,
        has_thinking,
        "turn completed"
    );

    // Record turn metrics
    counter!("agent_turns_total", "model" => model_name.clone()).increment(1);
    histogram!("agent_turn_duration_seconds", "model" => model_name.clone())
        .record(turn_start.elapsed().as_secs_f64());

    // Determine stop reason for this turn
    let stop_reason = determine_turn_stop_reason(
        tool_phase.stop_turn_requested,
        stream_result.tool_calls.len(),
        &stream_result.stop_reason,
    );

    let context_window_tokens = token_record_json
        .as_ref()
        .and_then(|r| r["computed"]["contextWindowTokens"].as_u64());

    TurnResult {
        success: true,
        tool_calls_executed: tool_phase.tool_calls_executed,
        token_usage: stream_result.token_usage,
        stop_reason,
        stop_turn_requested: tool_phase.stop_turn_requested,
        model: Some(model_name),
        latency_ms: duration,
        has_thinking,
        llm_stop_reason: Some(stream_result.stop_reason.clone()),
        context_window_tokens,
        ..Default::default()
    }
}

fn build_turn_context(
    context_manager: &mut ContextManager,
    registry: &ToolRegistry,
    run_context: &RunContext,
    server_origin: Option<&str>,
) -> Context {
    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.tools = Some(registry.definitions());
    context.skill_context.clone_from(&run_context.skill_context);
    context
        .subagent_results_context
        .clone_from(&run_context.subagent_results);
    context.task_context.clone_from(&run_context.task_context);
    context.dynamic_rules_context = run_context
        .dynamic_rules_context
        .clone()
        .or(context.dynamic_rules_context);
    context.server_origin = server_origin.map(String::from);
    context
        .device_context
        .clone_from(&run_context.device_context);
    context
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::content::AssistantContent;
    use tron_core::events::AssistantMessage;
    use tron_core::messages::TokenUsage;
    use tron_tools::traits::ExecutionMode;

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
        ToolCall::new(format!("tc-{name}"), name, Map::new())
    }

    /// Stub tool for wave builder tests — always Parallel.
    struct ParallelStub(&'static str);
    #[async_trait::async_trait]
    impl tron_tools::traits::TronTool for ParallelStub {
        fn name(&self) -> &str {
            self.0
        }
        fn category(&self) -> tron_core::tools::ToolCategory {
            tron_core::tools::ToolCategory::Custom
        }
        fn definition(&self) -> tron_core::tools::Tool {
            tron_core::tools::Tool {
                name: self.0.into(),
                description: String::new(),
                parameters: tron_core::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _: serde_json::Value,
            _: &tron_tools::traits::ToolContext,
        ) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
            Ok(tron_core::tools::text_result("ok", false))
        }
    }

    /// Stub tool that returns Serialized(group).
    struct SerializedStub {
        name: &'static str,
        group: &'static str,
    }
    #[async_trait::async_trait]
    impl tron_tools::traits::TronTool for SerializedStub {
        fn name(&self) -> &str {
            self.name
        }
        fn category(&self) -> tron_core::tools::ToolCategory {
            tron_core::tools::ToolCategory::Custom
        }
        fn execution_mode(&self) -> ExecutionMode {
            ExecutionMode::Serialized(self.group.into())
        }
        fn definition(&self) -> tron_core::tools::Tool {
            tron_core::tools::Tool {
                name: self.name.into(),
                description: String::new(),
                parameters: tron_core::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _: serde_json::Value,
            _: &tron_tools::traits::ToolContext,
        ) -> Result<tron_core::tools::TronToolResult, tron_tools::errors::ToolError> {
            Ok(tron_core::tools::text_result("ok", false))
        }
    }

    fn wave_registry(tools: Vec<Arc<dyn tron_tools::traits::TronTool>>) -> ToolRegistry {
        let mut reg = ToolRegistry::new();
        for t in tools {
            reg.register(t);
        }
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
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0, 1, 2]);
    }

    #[test]
    fn build_execution_waves_mixed() {
        // [Read(parallel), Browse₁(serialized:browser), Read(parallel), Browse₂(serialized:browser)]
        let reg = wave_registry(vec![
            Arc::new(ParallelStub("read")),
            Arc::new(SerializedStub {
                name: "browse",
                group: "browser",
            }),
        ]);
        let calls = vec![tc("read"), tc("browse"), tc("read"), tc("browse")];
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 2);
        assert_eq!(waves[0], vec![0, 1, 2]); // parallel + first browser
        assert_eq!(waves[1], vec![3]); // second browser
    }

    #[test]
    fn build_execution_waves_multiple_groups() {
        // [Browse₁(browser), Bash₁(shell), Browse₂(browser), Bash₂(shell)]
        let reg = wave_registry(vec![
            Arc::new(SerializedStub {
                name: "browse",
                group: "browser",
            }),
            Arc::new(SerializedStub {
                name: "bash",
                group: "shell",
            }),
        ]);
        let calls = vec![tc("browse"), tc("bash"), tc("browse"), tc("bash")];
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 2);
        assert_eq!(waves[0], vec![0, 1]); // first of each group
        assert_eq!(waves[1], vec![2, 3]); // second of each group
    }

    #[test]
    fn build_execution_waves_single_tool() {
        let reg = wave_registry(vec![Arc::new(ParallelStub("read"))]);
        let calls = vec![tc("read")];
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0]);
    }

    #[test]
    fn build_execution_waves_unknown_tool_defaults_parallel() {
        let reg = ToolRegistry::new(); // empty — no tools registered
        let calls = vec![tc("unknown1"), tc("unknown2")];
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 1);
        assert_eq!(waves[0], vec![0, 1]);
    }

    #[test]
    fn build_execution_waves_only_serialized() {
        let reg = wave_registry(vec![Arc::new(SerializedStub {
            name: "browse",
            group: "browser",
        })]);
        let calls = vec![tc("browse"), tc("browse"), tc("browse")];
        let waves = tools::build_execution_waves(&calls, &reg);
        assert_eq!(waves.len(), 3);
        assert_eq!(waves[0], vec![0]);
        assert_eq!(waves[1], vec![1]);
        assert_eq!(waves[2], vec![2]);
    }

    #[test]
    fn turn_result_interrupted_token_usage_none() {
        let result = TurnResult {
            success: true,
            interrupted: true,
            token_usage: None,
            stop_reason: Some(StopReason::Interrupted),
            ..Default::default()
        };
        assert!(result.interrupted);
        assert!(result.token_usage.is_none());
    }

    #[test]
    fn turn_result_interrupted_with_partial_usage() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 20,
            ..Default::default()
        };
        let result = TurnResult {
            success: true,
            interrupted: true,
            token_usage: Some(usage),
            stop_reason: Some(StopReason::Interrupted),
            ..Default::default()
        };
        assert!(result.interrupted);
        assert!(result.token_usage.is_some());
        assert_eq!(result.token_usage.unwrap().input_tokens, 100);
    }

    #[test]
    fn determine_turn_stop_reason_prefers_tool_stop() {
        let stop_reason = determine_turn_stop_reason(true, 2, "tool_use");
        assert_eq!(stop_reason, Some(StopReason::ToolStop));
    }

    #[test]
    fn determine_turn_stop_reason_uses_end_turn_for_empty_tool_batch() {
        let stop_reason = determine_turn_stop_reason(false, 0, "end_turn");
        assert_eq!(stop_reason, Some(StopReason::EndTurn));
    }

    #[test]
    fn determine_turn_stop_reason_uses_no_tool_calls_for_non_end_turn_completion() {
        let stop_reason = determine_turn_stop_reason(false, 0, "max_tokens");
        assert_eq!(stop_reason, Some(StopReason::NoToolCalls));
    }

    #[test]
    fn determine_turn_stop_reason_continues_after_tool_calls() {
        let stop_reason = determine_turn_stop_reason(false, 1, "tool_use");
        assert_eq!(stop_reason, None);
    }

    #[test]
    fn build_interrupted_message_payload_omits_empty_content() {
        let payload = build_interrupted_message_payload(
            &AssistantMessage {
                content: Vec::new(),
                token_usage: None,
            },
            None,
            3,
            "claude-opus-4-6",
            tron_core::messages::Provider::Anthropic,
        );

        assert!(payload.is_none());
    }

    #[test]
    fn build_interrupted_message_payload_preserves_thinking_and_usage() {
        let payload = build_interrupted_message_payload(
            &AssistantMessage {
                content: vec![AssistantContent::Thinking {
                    thinking: "thinking".into(),
                    signature: Some("sig".into()),
                }],
                token_usage: None,
            },
            Some(&TokenUsage {
                input_tokens: 11,
                output_tokens: 7,
                ..Default::default()
            }),
            2,
            "claude-opus-4-6",
            tron_core::messages::Provider::Anthropic,
        )
        .expect("thinking-only interrupted content should persist");

        assert_eq!(payload["turn"], 2);
        assert_eq!(payload["model"], "claude-opus-4-6");
        assert_eq!(payload["stopReason"], "interrupted");
        assert_eq!(payload["content"][0]["type"], "thinking");
        assert_eq!(payload["content"][0]["thinking"], "thinking");
        assert_eq!(payload["tokenUsage"]["inputTokens"], 11);
        assert_eq!(payload["tokenUsage"]["outputTokens"], 7);
    }
}
