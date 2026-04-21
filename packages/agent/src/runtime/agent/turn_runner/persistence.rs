use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

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

/// Emit an event, using sequenced emission when a counter is available.
fn emit_maybe_sequenced(emitter: &EventEmitter, event: TronEvent, counter: Option<&AtomicI64>) {
    if let Some(counter) = counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
}

/// Get next sequence value from counter, or None.
fn next_seq(counter: Option<&AtomicI64>) -> Option<i64> {
    counter.map(|c| c.fetch_add(1, Ordering::SeqCst) + 1)
}

/// Persist a `stream.turn_start` event, then broadcast the matching
/// `TurnStart` over the emitter.
///
/// INVARIANT (C5): the broadcast is emitted ONLY after the DB write
/// succeeds. If persistence fails, no subscriber sees the event, so iOS
/// and the DB cannot diverge — a reconnecting client that reconstructs
/// from the DB will see the same set of events as a live subscriber.
pub(super) async fn emit_turn_start(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    sequence_counter: Option<&AtomicI64>,
) {
    if let Some(persister) = persister {
        let seq = next_seq(sequence_counter);
        if let Err(error) = persister
            .append_with_sequence(
                session_id,
                EventType::StreamTurnStart,
                json!({ "turn": turn }),
                seq,
            )
            .await
        {
            warn!(session_id, turn, error = %error, "failed to persist turn-start event; skipping broadcast");
            return;
        }
    }
    emit_maybe_sequenced(
        emitter,
        TronEvent::TurnStart {
            base: BaseEvent::now(session_id),
            turn,
        },
        sequence_counter,
    );
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
    sequence_counter: Option<&AtomicI64>,
) {
    if let (Some(persister), Some(payload)) = (persister, payload) {
        let seq = next_seq(sequence_counter);
        if let Err(error) = persister
            .append_with_sequence(session_id, EventType::MessageAssistant, payload, seq)
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
    sequence_counter: Option<&AtomicI64>,
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

    emit_maybe_sequenced(emitter, TronEvent::ResponseComplete {
        base: BaseEvent::now(session_id),
        turn,
        stop_reason: stream_result.stop_reason.clone(),
        token_usage: response_token_usage,
        has_tool_calls: !stream_result.tool_calls.is_empty(),
        tool_call_count: stream_result.tool_calls.len() as u32,
        token_record: token_record_json,
        model: Some(model_name.to_owned()),
    }, sequence_counter);
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
    tracing::debug!(
        has_thinking,
        content_block_count = stream_result.message.content.len(),
        content_types = ?stream_result.message.content.iter().map(|c| match c {
            crate::core::content::AssistantContent::Text { .. } => "Text",
            crate::core::content::AssistantContent::Thinking { .. } => "Thinking",
            crate::core::content::AssistantContent::ToolUse { .. } => "ToolUse",
        }).collect::<Vec<_>>(),
        "persistence: add_assistant_message_to_context"
    );
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
    sequence_counter: Option<&AtomicI64>,
) {
    if let Some(persister) = persister {
        let seq = next_seq(sequence_counter);
        if let Err(error) = persister
            .append_with_sequence(session_id, EventType::MessageAssistant, payload, seq)
            .await
        {
            error!(
                session_id,
                error = %error,
                "failed to persist message.assistant"
            );
        }
    }
}

pub(super) async fn persist_rules_activated(
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    activated_rules: &[ActivatedRuleInfo],
    total_activated: u32,
    sequence_counter: Option<&AtomicI64>,
) {
    if let Some(persister) = persister {
        let seq = next_seq(sequence_counter);
        if let Err(error) = persister
            .append_background_with_sequence(
                session_id,
                EventType::RulesActivated,
                json!({
                    "rules": activated_rules.iter().map(|a| json!({
                        "relativePath": a.relative_path,
                        "scopeDir": a.scope_dir,
                    })).collect::<Vec<_>>(),
                    "totalActivated": total_activated,
                }),
                seq,
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
}

/// Persist a `stream.turn_end` event, then broadcast the matching `TurnEnd`.
///
/// INVARIANT (C5): persist before broadcast. On persist failure the broadcast
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
) {
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
        if let Some(ref token_record) = token_record_json {
            payload["tokenRecord"] = token_record.clone();
        }
        if let Some(cost) = cost {
            payload["cost"] = json!(cost);
        }

        let seq = next_seq(sequence_counter);
        if let Err(error) = persister
            .append_with_sequence(session_id, EventType::StreamTurnEnd, payload, seq)
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

    let turn_token_usage = stream_result.token_usage.as_ref().map(|u| TurnTokenUsage {
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        cache_read_tokens: u.cache_read_tokens,
        cache_creation_tokens: u.cache_creation_tokens,
        ..TurnTokenUsage::default()
    });

    emit_maybe_sequenced(
        emitter,
        TronEvent::TurnEnd {
            base: BaseEvent::now(session_id),
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

pub(super) fn emit_tool_use_batch(
    emitter: &Arc<EventEmitter>,
    session_id: &str,
    tool_calls: &[crate::core::messages::ToolCall],
    sequence_counter: Option<&AtomicI64>,
) {
    let summaries: Vec<ToolCallSummary> = tool_calls
        .iter()
        .map(|tool_call| ToolCallSummary {
            id: tool_call.id.clone(),
            name: tool_call.name.clone(),
            arguments: tool_call.arguments.clone(),
        })
        .collect();

    emit_maybe_sequenced(emitter, TronEvent::ToolUseBatch {
        base: BaseEvent::now(session_id),
        tool_calls: summaries,
    }, sequence_counter);
}

#[cfg(test)]
mod tests {
    //! Tests guard the C5 invariant: turn-start and turn-end persist to the
    //! event store BEFORE broadcasting the matching TronEvent. Pre-fix code
    //! broadcast first, so a persist failure left iOS subscribers with an
    //! event the DB never recorded — reconstruction on reconnect diverged.
    use super::*;
    use crate::events::sqlite::connection::{self, ConnectionConfig};
    use crate::events::sqlite::migrations::run_migrations;
    use crate::events::sqlite::repositories::event::ListEventsOptions;
    use crate::events::EventStore;
    use crate::runtime::types::StreamResult;
    use std::sync::Arc;
    use std::sync::atomic::AtomicI64;

    struct Harness {
        emitter: Arc<EventEmitter>,
        persister: EventPersister,
        store: Arc<EventStore>,
        session_id: String,
        counter: AtomicI64,
        rx: tokio::sync::broadcast::Receiver<TronEvent>,
    }

    async fn harness() -> Harness {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("m", "/tmp", Some("t"), None, None, None)
            .unwrap();
        let emitter = Arc::new(EventEmitter::new());
        let rx = emitter.subscribe();
        let persister = EventPersister::new(Arc::clone(&store));
        Harness {
            emitter,
            persister,
            store,
            session_id: session.session.id,
            counter: AtomicI64::new(0),
            rx,
        }
    }

    fn persisted_events(store: &EventStore, sid: &str, event_type: &str) -> Vec<i64> {
        store
            .get_events_by_session(sid, &ListEventsOptions::default())
            .unwrap()
            .into_iter()
            .filter(|e| e.event_type == event_type)
            .map(|e| e.sequence)
            .collect()
    }

    #[tokio::test]
    async fn emit_turn_start_persists_before_broadcasting() {
        let mut h = harness().await;

        emit_turn_start(&h.emitter, Some(&h.persister), &h.session_id, 1, Some(&h.counter)).await;

        // Collect the broadcast event.
        let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        let broadcast_seq = broadcast.sequence().expect("sequenced event");

        // Persister is synchronous in emit_turn_start now, but flush to be safe.
        h.persister.flush().await.unwrap();
        let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_start");

        assert_eq!(persisted.len(), 1, "one stream.turn_start row expected");
        assert!(
            persisted[0] < broadcast_seq,
            "persist (seq {}) must precede broadcast (seq {})",
            persisted[0],
            broadcast_seq
        );
    }

    #[tokio::test]
    async fn emit_turn_start_without_persister_still_broadcasts() {
        // When no persister is configured (pure live emit, used by some test
        // harnesses), the function must still broadcast — no regression for
        // emitter-only callers.
        let mut h = harness().await;

        emit_turn_start(&h.emitter, None, &h.session_id, 1, Some(&h.counter)).await;

        let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        assert_eq!(broadcast.event_type(), "turn_start");
    }

    #[tokio::test]
    async fn emit_turn_start_skips_broadcast_on_persist_failure() {
        // Kill the persister worker so append_with_sequence returns an error.
        // The function must detect that and NOT emit the broadcast.
        let mut h = harness().await;
        h.persister.worker_handle.abort();
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;

        emit_turn_start(&h.emitter, Some(&h.persister), &h.session_id, 1, Some(&h.counter)).await;

        // A broadcast would arrive immediately if the emit fired — give it a
        // short window, then confirm no event appeared.
        let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
        assert!(
            result.is_err(),
            "no broadcast should fire when persist fails, got: {result:?}"
        );
    }

    fn stream_result_stub() -> StreamResult {
        StreamResult {
            message: crate::core::events::AssistantMessage {
                content: Vec::new(),
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
            token_usage: None,
            tool_calls: Vec::new(),
            interrupted: false,
            partial_content: None,
            ttft_ms: None,
        }
    }

    #[tokio::test]
    async fn emit_turn_end_persists_before_broadcasting() {
        let mut h = harness().await;
        let stream = stream_result_stub();

        emit_turn_end(
            &h.emitter,
            Some(&h.persister),
            &h.session_id,
            1,
            42,
            &stream,
            None,
            None,
            25_000,
            "m",
            Some(&h.counter),
        )
        .await;

        let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        let broadcast_seq = broadcast.sequence().expect("sequenced event");

        h.persister.flush().await.unwrap();
        let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_end");

        assert_eq!(persisted.len(), 1);
        assert!(
            persisted[0] < broadcast_seq,
            "persist (seq {}) must precede broadcast (seq {})",
            persisted[0],
            broadcast_seq
        );
    }

    #[tokio::test]
    async fn emit_turn_end_skips_broadcast_on_persist_failure() {
        let mut h = harness().await;
        h.persister.worker_handle.abort();
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        let stream = stream_result_stub();

        emit_turn_end(
            &h.emitter,
            Some(&h.persister),
            &h.session_id,
            1,
            42,
            &stream,
            None,
            None,
            25_000,
            "m",
            Some(&h.counter),
        )
        .await;

        let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
        assert!(
            result.is_err(),
            "no broadcast should fire when persist fails, got: {result:?}"
        );
    }
}
