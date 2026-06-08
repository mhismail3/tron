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
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::pipeline::persistence;
use crate::domains::agent::r#loop::types::StreamResult;
use crate::engine::{InvocationId, TraceId};

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
mod tests {
    //! Tests guard the persist-before-broadcast invariant: turn-start and
    //! turn-end persist to the event store BEFORE broadcasting the matching
    //! TronEvent. Broadcasting first would let a persist failure leave iOS
    //! subscribers with an event the DB never recorded, so reconstruction on
    //! reconnect would diverge from what live clients already rendered.
    use super::*;
    use crate::domains::agent::r#loop::types::StreamResult;
    use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;
    use crate::domains::session::event_store::sqlite::repositories::event::ListEventsOptions;
    use crate::domains::session::event_store::{AppendOptions, EventStore};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicI64, Ordering};

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
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
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

    fn persisted_payloads(store: &EventStore, sid: &str, event_type: &str) -> Vec<Value> {
        store
            .get_events_by_session(sid, &ListEventsOptions::default())
            .unwrap()
            .into_iter()
            .filter(|e| e.event_type == event_type)
            .map(|e| serde_json::from_str(&e.payload).expect("valid persisted event payload"))
            .collect()
    }

    #[tokio::test]
    async fn emit_turn_start_persists_before_broadcasting() {
        let mut h = harness().await;

        emit_turn_start(
            &h.emitter,
            Some(&h.persister),
            &h.session_id,
            1,
            Some(&h.counter),
            None,
            None,
        )
        .await;

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
        assert_eq!(
            persisted[0], broadcast_seq,
            "persisted and broadcast turn-start events must share a sequence"
        );
    }

    #[tokio::test]
    async fn emit_turn_start_advances_stale_sequence_counter_from_db() {
        let mut h = harness().await;
        let inserted = h
            .store
            .append(&AppendOptions {
                session_id: &h.session_id,
                event_type: EventType::MetadataUpdate,
                payload: json!({"kind": "preexisting"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        assert_eq!(inserted.sequence, 1);
        assert_eq!(
            h.counter.load(Ordering::SeqCst),
            0,
            "test setup keeps the runtime counter stale"
        );

        emit_turn_start(
            &h.emitter,
            Some(&h.persister),
            &h.session_id,
            1,
            Some(&h.counter),
            None,
            None,
        )
        .await;

        let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_start");
        assert_eq!(persisted, vec![2]);
        assert_eq!(broadcast.sequence(), Some(2));
        assert_eq!(h.counter.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn emit_turn_start_without_persister_still_broadcasts() {
        // When no persister is configured (pure live emit, used by some test
        // harnesses), the function must still broadcast — no regression for
        // emitter-only callers.
        let mut h = harness().await;

        emit_turn_start(
            &h.emitter,
            None,
            &h.session_id,
            1,
            Some(&h.counter),
            None,
            None,
        )
        .await;

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

        emit_turn_start(
            &h.emitter,
            Some(&h.persister),
            &h.session_id,
            1,
            Some(&h.counter),
            None,
            None,
        )
        .await;

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
            message: crate::shared::protocol::events::AssistantMessage {
                content: Vec::new(),
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
            token_usage: None,
            capability_invocations: Vec::new(),
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
            None,
            None,
        )
        .await;

        let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
            .await
            .expect("broadcast should arrive")
            .expect("broadcast channel alive");
        let broadcast_seq = broadcast.sequence().expect("sequenced event");

        h.persister.flush().await.unwrap();
        let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_end");
        let payloads = persisted_payloads(&h.store, &h.session_id, "stream.turn_end");

        assert_eq!(persisted.len(), 1);
        assert!(
            payloads[0].get("tokenUsage").is_none(),
            "turn_end without provider usage must not persist synthetic zero-token usage"
        );
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
            None,
            None,
        )
        .await;

        let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
        assert!(
            result.is_err(),
            "no broadcast should fire when persist fails, got: {result:?}"
        );
    }

    // ── Persist-before-broadcast: response-complete events ─────────────────

    #[tokio::test]
    async fn persist_completed_assistant_message_returns_ok_on_success() {
        let h = harness().await;
        let payload = json!({ "content": [], "turn": 1 });
        let result = persist_completed_assistant_message(
            Some(&h.persister),
            &h.session_id,
            payload,
            Some(&h.counter),
        )
        .await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn persist_completed_assistant_message_returns_err_on_worker_death() {
        let h = harness().await;
        h.persister.worker_handle.abort();
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;

        let payload = json!({ "content": [], "turn": 1 });
        let result = persist_completed_assistant_message(
            Some(&h.persister),
            &h.session_id,
            payload,
            Some(&h.counter),
        )
        .await;
        assert!(
            result.is_err(),
            "persist must surface error when worker is dead"
        );
    }

    #[tokio::test]
    async fn persist_completed_assistant_message_is_noop_when_no_persister() {
        // Callers that pass None (tests, pure-live-emit contexts) must get
        // Ok so they proceed to emit ResponseComplete — no persister, no
        // failure mode to guard against.
        let h = harness().await;
        let payload = json!({ "content": [], "turn": 1 });
        let result =
            persist_completed_assistant_message(None, &h.session_id, payload, Some(&h.counter))
                .await;
        assert!(result.is_ok());
    }
}
