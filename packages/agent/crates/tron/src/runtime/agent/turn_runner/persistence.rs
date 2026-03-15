use std::sync::Arc;

use serde_json::{Value, json};
use tracing::{error, warn};
use crate::core::events::{
    ActivatedRuleInfo, AssistantMessage, BaseEvent, ResponseTokenUsage, ToolCallSummary, TronEvent,
    TurnTokenUsage,
};
use crate::core::messages::{Provider, TokenUsage};
use crate::events::EventType;

use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::context::context_manager::ContextManager;
use crate::runtime::orchestrator::event_persister::EventPersister;
use crate::runtime::pipeline::persistence;
use crate::runtime::types::StreamResult;

pub(super) async fn emit_turn_start(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
) {
    let _ = emitter.emit(TronEvent::TurnStart {
        base: BaseEvent::now(session_id),
        turn,
    });
    if let Some(persister) = persister
        && let Err(error) = persister
            .append_background(
                session_id,
                EventType::StreamTurnStart,
                json!({
                    "turn": turn,
                }),
            )
            .await
    {
        warn!(session_id, turn, error = %error, "failed to queue turn-start event");
    }
}

pub(super) fn build_interrupted_message_payload(
    message: &AssistantMessage,
    token_usage: Option<&TokenUsage>,
    turn: u32,
    model: &str,
    provider_type: Provider,
) -> Option<Value> {
    let content_json = persistence::build_content_json(&message.content);
    if content_json.is_empty() {
        return None;
    }

    let mut payload = json!({
        "content": content_json,
        "turn": turn,
        "model": model,
        "stopReason": "interrupted",
        "interrupted": true,
        "providerType": provider_type.as_str(),
        "tokenUsageAvailable": token_usage.is_some(),
    });
    if let Some(token_usage) = token_usage {
        payload["tokenUsage"] = persistence::build_token_usage_json(token_usage);
    }
    Some(payload)
}

pub(super) async fn persist_interrupted_message(
    persister: Option<&EventPersister>,
    session_id: &str,
    payload: Option<Value>,
) {
    if let (Some(persister), Some(payload)) = (persister, payload)
        && let Err(error) = persister
            .append(session_id, EventType::MessageAssistant, payload)
            .await
    {
        error!(
            session_id,
            error = %error,
            "failed to persist interrupted message.assistant"
        );
    }
}

pub(super) fn build_token_record_json(
    token_usage: Option<&TokenUsage>,
    provider_type: Provider,
    session_id: &str,
    turn: u32,
    previous_context_baseline: u64,
    model: &str,
) -> (Option<Value>, Option<f64>) {
    let mut token_record_json = token_usage.map(|usage| {
        persistence::build_token_record(
            usage,
            provider_type,
            session_id,
            turn,
            previous_context_baseline,
        )
    });

    let cost = token_usage
        .and_then(|usage| crate::llm::tokens::calculate_cost(model, usage).map(|c| c.total));

    if let Some(record) = token_record_json.as_mut() {
        record["pricing"] = if cost.is_some() {
            json!({ "available": true })
        } else {
            json!({
                "available": false,
                "reason": "unsupported_model_pricing",
                "model": model,
            })
        };
    }

    (token_record_json, cost)
}

pub(super) fn emit_response_complete(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    turn: u32,
    stream_result: &StreamResult,
    token_record_json: Option<Value>,
    model_name: &str,
) {
    let response_token_usage = stream_result
        .token_usage
        .as_ref()
        .map(|u| ResponseTokenUsage {
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            cache_read_tokens: u.cache_read_tokens,
            cache_creation_tokens: u.cache_creation_tokens,
            cache_creation_5m_tokens: u.cache_creation_5m_tokens,
            cache_creation_1h_tokens: u.cache_creation_1h_tokens,
            provider_type: None,
        });

    let _ = emitter.emit(TronEvent::ResponseComplete {
        base: BaseEvent::now(session_id),
        turn,
        stop_reason: stream_result.stop_reason.clone(),
        token_usage: response_token_usage,
        has_tool_calls: !stream_result.tool_calls.is_empty(),
        tool_call_count: stream_result.tool_calls.len() as u32,
        token_record: token_record_json,
        model: Some(model_name.to_owned()),
    });
}

pub(super) fn add_assistant_message_to_context(
    context_manager: &mut ContextManager,
    stream_result: &StreamResult,
) -> bool {
    let has_thinking = stream_result
        .message
        .content
        .iter()
        .any(|c| matches!(c, crate::core::content::AssistantContent::Thinking { .. }));
    let thinking_text = stream_result.message.content.iter().find_map(|c| {
        if let crate::core::content::AssistantContent::Thinking { thinking, .. } = c {
            Some(thinking.clone())
        } else {
            None
        }
    });
    let stop_reason_for_context: Option<crate::core::messages::StopReason> =
        serde_json::from_value(serde_json::Value::String(stream_result.stop_reason.clone())).ok();

    context_manager.add_message(crate::core::messages::Message::Assistant {
        content: stream_result.message.content.clone(),
        usage: stream_result.token_usage.clone(),
        cost: None,
        stop_reason: stop_reason_for_context,
        thinking: thinking_text,
    });

    if let Some(token_usage) = stream_result.token_usage.as_ref() {
        context_manager
            .set_api_context_tokens(token_usage.input_tokens + token_usage.output_tokens);
    }

    has_thinking
}

pub(super) fn build_completed_assistant_payload(
    stream_result: &StreamResult,
    turn: u32,
    model: &str,
    latency_ms: u64,
    has_thinking: bool,
    provider_type: Provider,
    token_record_json: Option<&Value>,
    cost: Option<f64>,
) -> Value {
    let mut payload = json!({
        "content": persistence::build_content_json(&stream_result.message.content),
        "turn": turn,
        "model": model,
        "latency": latency_ms,
        "stopReason": &stream_result.stop_reason,
        "hasThinking": has_thinking,
        "providerType": provider_type.as_str(),
    });
    if let Some(token_usage) = stream_result.token_usage.as_ref() {
        payload["tokenUsage"] = persistence::build_token_usage_json(token_usage);
    }
    if let Some(token_record_json) = token_record_json {
        payload["tokenRecord"] = token_record_json.clone();
    }
    if let Some(cost) = cost {
        payload["cost"] = json!(cost);
    }
    payload
}

pub(super) async fn persist_completed_assistant_message(
    persister: Option<&EventPersister>,
    session_id: &str,
    payload: Value,
) {
    if let Some(persister) = persister
        && let Err(error) = persister
            .append(session_id, EventType::MessageAssistant, payload)
            .await
    {
        error!(
            session_id,
            error = %error,
            "failed to persist message.assistant"
        );
    }
}

pub(super) async fn persist_rules_activated(
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    activated_rules: &[ActivatedRuleInfo],
    total_activated: u32,
) {
    if let Some(persister) = persister
        && let Err(error) = persister
            .append_background(
                session_id,
                EventType::RulesActivated,
                json!({
                    "rules": activated_rules.iter().map(|a| json!({
                        "relativePath": a.relative_path,
                        "scopeDir": a.scope_dir,
                    })).collect::<Vec<_>>(),
                    "totalActivated": total_activated,
                }),
            )
            .await
    {
        warn!(
            session_id,
            turn,
            error = %error,
            "failed to queue rules-activated event"
        );
    }
}

pub(super) async fn emit_turn_end(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    duration_ms: u64,
    stream_result: &StreamResult,
    token_record_json: Option<Value>,
    cost: Option<f64>,
    context_limit: u64,
    model_name: &str,
) {
    let turn_token_usage = stream_result.token_usage.as_ref().map(|u| TurnTokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
        ..TurnTokenUsage::default()
    });

    let _ = emitter.emit(TronEvent::TurnEnd {
        base: BaseEvent::now(session_id),
        turn,
        duration: duration_ms,
        token_usage: turn_token_usage,
        token_record: token_record_json.clone(),
        cost,
        stop_reason: Some(stream_result.stop_reason.clone()),
        context_limit: Some(context_limit),
        model: Some(model_name.to_owned()),
    });

    if let Some(persister) = persister {
        let mut token_usage_object = json!({
            "inputTokens": stream_result.token_usage.as_ref().map_or(0, |u| u.input_tokens),
            "outputTokens": stream_result.token_usage.as_ref().map_or(0, |u| u.output_tokens),
        });
        if let Some(token_usage) = stream_result.token_usage.as_ref() {
            if let Some(cache_read_tokens) = token_usage.cache_read_tokens {
                token_usage_object["cacheReadTokens"] = json!(cache_read_tokens);
            }
            if let Some(cache_creation_tokens) = token_usage.cache_creation_tokens {
                token_usage_object["cacheCreationTokens"] = json!(cache_creation_tokens);
            }
        }

        let mut payload = json!({
            "turn": turn,
            "tokenUsage": token_usage_object,
            "stopReason": &stream_result.stop_reason,
            "contextLimit": context_limit,
        });
        if let Some(token_record_json) = token_record_json {
            payload["tokenRecord"] = token_record_json;
        }
        if let Some(cost) = cost {
            payload["cost"] = json!(cost);
        }

        if let Err(error) = persister
            .append_background(session_id, EventType::StreamTurnEnd, payload)
            .await
        {
            warn!(
                session_id,
                turn,
                error = %error,
                "failed to queue turn-end event"
            );
        }
    }
}

pub(super) fn emit_tool_use_batch(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    tool_calls: &[crate::core::messages::ToolCall],
) {
    let summaries: Vec<ToolCallSummary> = tool_calls
        .iter()
        .map(|tool_call| ToolCallSummary {
            id: tool_call.id.clone(),
            name: tool_call.name.clone(),
            arguments: tool_call.arguments.clone(),
        })
        .collect();

    let _ = emitter.emit(TronEvent::ToolUseBatch {
        base: BaseEvent::now(session_id),
        tool_calls: summaries,
    });
}
