use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use crate::domains::session::event_store::EventType;
use crate::shared::protocol::events::{
    AssistantMessage, BaseEvent, CapabilityInvocationSummary, TronEvent,
};
use crate::shared::protocol::messages::{Provider, TokenUsage};
use serde_json::{Value, json};
use tracing::{error, warn};

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::pipeline::persistence;
use crate::domains::agent::r#loop::types::StreamResult;
use crate::engine::{InvocationId, TraceId};
use crate::shared::protocol::model_audit::ModelProviderRequestAudit;

fn base_event(
    session_id: &str,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> BaseEvent {
    BaseEvent::now(session_id).with_trace_context(
        trace_id.map(|id| id.as_str().to_owned()),
        parent_invocation_id.map(|id| id.as_str().to_owned()),
    )
}

/// Emit an event, using sequenced emission when a counter is available.
fn emit_maybe_sequenced(emitter: &EventEmitter, event: TronEvent, counter: Option<&AtomicI64>) {
    if let Some(counter) = counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}

fn advance_counter_at_least(counter: Option<&AtomicI64>, floor: i64) {
    let Some(counter) = counter else {
        return;
    };
    let mut current = counter.load(Ordering::SeqCst);
    while current < floor {
        match counter.compare_exchange(current, floor, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => break,
            Err(next) => current = next,
        }
    }
}

/// Persist a `stream.turn_start` event, then broadcast the matching
/// `TurnStart` over the emitter.
///
/// INVARIANT: the broadcast is emitted ONLY after the DB write
/// succeeds. If persistence fails, no subscriber sees the event, so iOS
/// and the DB cannot diverge — a reconnecting client that reconstructs
/// from the DB will see the same set of events as a live subscriber.
/// The persisted and broadcast events share the same sequence; when a
/// resumed session's in-memory counter is behind the DB, the DB allocator
/// wins and the counter is advanced before any later pre-assigned events.
pub(super) async fn emit_turn_start(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    sequence_counter: Option<&AtomicI64>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) {
    if let Some(persister) = persister {
        let row = match persister
            .append(
                session_id,
                EventType::StreamTurnStart,
                json!({ "turn": turn }),
            )
            .await
        {
            Ok(row) => row,
            Err(error) => {
                warn!(session_id, turn, error = %error, "failed to persist turn-start event; skipping broadcast");
                return;
            }
        };
        advance_counter_at_least(sequence_counter, row.sequence);
        let _ = emitter.emit(TronEvent::TurnStart {
            base: base_event(session_id, trace_id, parent_invocation_id)
                .with_sequence(row.sequence),
            turn,
        });
        return;
    }
    emit_maybe_sequenced(
        emitter,
        TronEvent::TurnStart {
            base: base_event(session_id, trace_id, parent_invocation_id),
            turn,
        },
        sequence_counter,
    );
}

pub(super) fn build_interrupted_message_payload(
    message: &AssistantMessage,
    token_usage: Option<&TokenUsage>,
    session_id: &str,
    turn: u32,
    model: &str,
    provider_type: Provider,
    previous_context_baseline: u64,
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
        payload["tokenRecord"] = persistence::build_token_record(
            token_usage,
            provider_type,
            session_id,
            turn,
            previous_context_baseline,
            model,
        );
    }
    Some(payload)
}

/// Persist the provider request audit before the model stream is opened.
///
/// INVARIANT: callers must complete this write before invoking
/// `ModelResponder::respond`. If the write fails, the provider stream must not
/// be opened because replay would be missing the exact request that produced
/// the response.
pub(super) async fn persist_model_provider_request_audit(
    persister: Option<&EventPersister>,
    session_id: &str,
    audit: &ModelProviderRequestAudit,
    sequence_counter: Option<&AtomicI64>,
) -> Result<(), RuntimeError> {
    let Some(persister) = persister else {
        return Ok(());
    };
    let payload = serde_json::to_value(audit).map_err(|error| {
        RuntimeError::Persistence(format!(
            "failed to serialize model provider request: {error}"
        ))
    })?;
    persister
        .append_with_runtime_sequence(
            session_id,
            EventType::ModelProviderRequest,
            payload,
            sequence_counter,
        )
        .await?;
    Ok(())
}

pub(super) async fn persist_interrupted_message(
    persister: Option<&EventPersister>,
    session_id: &str,
    payload: Option<Value>,
    sequence_counter: Option<&AtomicI64>,
) {
    if let (Some(persister), Some(payload)) = (persister, payload) {
        if let Err(error) = persister
            .append_with_runtime_sequence(
                session_id,
                EventType::MessageAssistant,
                payload,
                sequence_counter,
            )
            .await
        {
            error!(
                session_id,
                error = %error,
                "failed to persist interrupted message.assistant"
            );
        }
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
    let token_record_json = token_usage.map(|usage| {
        persistence::build_token_record(
            usage,
            provider_type,
            session_id,
            turn,
            previous_context_baseline,
            model,
        )
    });

    let cost = token_record_json
        .as_ref()
        .and_then(|record| record.get("pricing"))
        .and_then(|pricing| pricing.get("cost"))
        .and_then(|cost| cost.get("totalCost"))
        .and_then(Value::as_f64);

    (token_record_json, cost)
}

pub(super) fn emit_response_complete(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    turn: u32,
    stream_result: &StreamResult,
    token_record_json: Option<Value>,
    model_name: &str,
    sequence_counter: Option<&AtomicI64>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) {
    let response_token_usage = stream_result.token_usage.as_ref().map(|u| TokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cached_input_tokens: u.cached_input_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
        cache_creation_5m_tokens: u.cache_creation_5m_tokens,
        cache_creation_1h_tokens: u.cache_creation_1h_tokens,
        reasoning_output_tokens: u.reasoning_output_tokens,
        thought_tokens: u.thought_tokens,
        tool_use_prompt_tokens: u.tool_use_prompt_tokens,
        total_tokens: u.total_tokens,
        provider_type: u.provider_type,
    });

    emit_maybe_sequenced(
        emitter,
        TronEvent::ResponseComplete {
            base: base_event(session_id, trace_id, parent_invocation_id),
            turn,
            stop_reason: stream_result.stop_reason.clone(),
            token_usage: response_token_usage,
            has_capability_invocations: !stream_result.capability_invocations.is_empty(),
            capability_invocation_count: stream_result.capability_invocations.len() as u32,
            token_record: token_record_json,
            model: Some(model_name.to_owned()),
        },
        sequence_counter,
    );
}

pub(super) fn add_assistant_message_to_context(
    context_manager: &mut ContextManager,
    stream_result: &StreamResult,
) -> bool {
    let has_thinking = stream_result.message.content.iter().any(|c| {
        matches!(
            c,
            crate::shared::protocol::content::AssistantContent::Thinking { .. }
        )
    });
    tracing::debug!(
        has_thinking,
        content_block_count = stream_result.message.content.len(),
        content_types = ?stream_result.message.content.iter().map(|c| match c {
            crate::shared::protocol::content::AssistantContent::Text { .. } => "Text",
            crate::shared::protocol::content::AssistantContent::Thinking { .. } => "Thinking",
            crate::shared::protocol::content::AssistantContent::CapabilityInvocation { .. } => "CapabilityInvocation",
        }).collect::<Vec<_>>(),
        "persistence: add_assistant_message_to_context"
    );
    let thinking_text = stream_result.message.content.iter().find_map(|c| {
        if let crate::shared::protocol::content::AssistantContent::Thinking { thinking, .. } = c {
            Some(thinking.clone())
        } else {
            None
        }
    });
    let stop_reason_for_context: Option<crate::shared::protocol::messages::StopReason> =
        match serde_json::from_value::<crate::shared::protocol::messages::StopReason>(
            serde_json::Value::String(stream_result.stop_reason.clone()),
        ) {
            Ok(sr) => Some(sr),
            Err(e) => {
                tracing::warn!(
                    raw_stop_reason = %stream_result.stop_reason,
                    error = %e,
                    "persistence: unrecognized stop_reason from provider; stored as None. \
                     This likely means the provider added a new stop_reason that our \
                     StopReason enum does not yet model."
                );
                None
            }
        };

    context_manager.add_message(crate::shared::protocol::messages::Message::Assistant {
        content: stream_result.message.content.clone(),
        usage: stream_result.token_usage.clone().map(Box::new),
        cost: None,
        stop_reason: stop_reason_for_context,
        thinking: thinking_text,
    });

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

/// Persist a completed `message.assistant` event synchronously.
///
/// INVARIANT: returns the persist error to the caller so that the
/// corresponding `ResponseComplete` broadcast can be gated on successful
/// persistence. A silent log-and-continue here would let `ResponseComplete`
/// reach iOS with no matching message in the event log.
pub(super) async fn persist_completed_assistant_message(
    persister: Option<&EventPersister>,
    session_id: &str,
    payload: Value,
    sequence_counter: Option<&AtomicI64>,
) -> Result<(), crate::domains::agent::r#loop::errors::RuntimeError> {
    let Some(persister) = persister else {
        return Ok(());
    };
    persister
        .append_with_runtime_sequence(
            session_id,
            EventType::MessageAssistant,
            payload,
            sequence_counter,
        )
        .await
        .map(|_| ())
        .inspect_err(|error| {
            error!(
                session_id,
                error = %error,
                "failed to persist message.assistant"
            );
        })
}

/// Persist a `stream.turn_end` event, then broadcast the matching `TurnEnd`.
///
/// INVARIANT: persist before broadcast. On persist failure the broadcast
/// is skipped so iOS subscribers and the persisted DB state stay consistent.
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
    sequence_counter: Option<&AtomicI64>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) {
    if let Some(persister) = persister {
        let mut payload = json!({
            "turn": turn,
            "stopReason": &stream_result.stop_reason,
            "contextLimit": context_limit,
        });
        if let Some(token_usage) = stream_result.token_usage.as_ref() {
            payload["tokenUsage"] = persistence::build_token_usage_json(token_usage);
        }
        if let Some(ref token_record) = token_record_json {
            payload["tokenRecord"] = token_record.clone();
        }
        if let Some(cost) = cost {
            payload["cost"] = json!(cost);
        }

        if let Err(error) = persister
            .append_with_runtime_sequence(
                session_id,
                EventType::StreamTurnEnd,
                payload,
                sequence_counter,
            )
            .await
        {
            warn!(
                session_id,
                turn,
                error = %error,
                "failed to persist turn-end event; skipping broadcast"
            );
            return;
        }
    }

    let turn_token_usage = stream_result.token_usage.as_ref().map(|u| TokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cached_input_tokens: u.cached_input_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
        cache_creation_5m_tokens: u.cache_creation_5m_tokens,
        cache_creation_1h_tokens: u.cache_creation_1h_tokens,
        reasoning_output_tokens: u.reasoning_output_tokens,
        thought_tokens: u.thought_tokens,
        tool_use_prompt_tokens: u.tool_use_prompt_tokens,
        total_tokens: u.total_tokens,
        provider_type: u.provider_type,
    });

    emit_maybe_sequenced(
        emitter,
        TronEvent::TurnEnd {
            base: base_event(session_id, trace_id, parent_invocation_id),
            turn,
            duration: duration_ms,
            token_usage: turn_token_usage,
            token_record: token_record_json,
            cost,
            stop_reason: Some(stream_result.stop_reason.clone()),
            context_limit: Some(context_limit),
            model: Some(model_name.to_owned()),
        },
        sequence_counter,
    );
}

pub(super) fn emit_capability_invocation_batch(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    capability_invocations: &[crate::shared::protocol::messages::CapabilityInvocationDraft],
    sequence_counter: Option<&AtomicI64>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) {
    let summaries: Vec<CapabilityInvocationSummary> = capability_invocations
        .iter()
        .map(|capability_invocation| CapabilityInvocationSummary {
            id: capability_invocation.id.clone(),
            name: capability_invocation.name.clone(),
            arguments: capability_invocation.arguments.clone(),
        })
        .collect();

    emit_maybe_sequenced(
        emitter,
        TronEvent::CapabilityInvocationBatch {
            base: base_event(session_id, trace_id, parent_invocation_id),
            capability_invocations: summaries,
        },
        sequence_counter,
    );
}

#[cfg(test)]
mod tests;
