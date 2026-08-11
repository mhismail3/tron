//! Tests guard the persist-before-broadcast invariant: turn-start and
//! turn-end persist to the event store BEFORE broadcasting the matching
//! TronEvent. Broadcasting first would let a persist failure leave iOS
//! subscribers with an event the DB never recorded, so reconstruction on
//! reconnect would diverge from what live clients already rendered.
use super::*;
use crate::domains::agent::r#loop::types::StreamResult;
use crate::domains::session::event_store::ListEventsOptions;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::schema::ensure_schema;
use crate::domains::session::event_store::{AppendOptions, EventStore};
use crate::shared::protocol::messages::ToolInvocationDraft;
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

fn harness() -> Harness {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        ensure_schema(&conn).unwrap();
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
    let mut h = harness();

    emit_turn_start(
        &h.emitter,
        Some(&h.persister),
        &h.session_id,
        1,
        None,
        Some(&h.counter),
        None,
        None,
    )
    .unwrap();

    // Collect the broadcast event.
    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
        .await
        .expect("broadcast should arrive")
        .expect("broadcast channel alive");
    let broadcast_seq = broadcast.sequence().expect("sequenced event");

    let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_start");

    assert_eq!(persisted.len(), 1, "one stream.turn_start row expected");
    assert_eq!(
        persisted[0], broadcast_seq,
        "persisted and broadcast turn-start events must share a sequence"
    );
}

#[tokio::test]
async fn emit_turn_start_persists_and_broadcasts_delivery_continuation() {
    let mut h = harness();
    let continuation = json!({
        "deliveries":[{
            "deliveryId":"delivery-1",
            "sourceKind":"worker_result",
            "sourceWorkerName":"General Delegate",
            "triggeredWake":true,
            "redelivery":false
        }]
    });

    emit_turn_start(
        &h.emitter,
        Some(&h.persister),
        &h.session_id,
        1,
        Some(continuation.clone()),
        Some(&h.counter),
        None,
        None,
    )
    .unwrap();

    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
        .await
        .expect("broadcast should arrive")
        .expect("broadcast channel alive");
    assert!(matches!(
        broadcast,
        TronEvent::TurnStart {
            agent_delivery_continuation: Some(ref value),
            ..
        } if value == &continuation
    ));

    let payloads = persisted_payloads(&h.store, &h.session_id, "stream.turn_start");
    assert_eq!(
        payloads[0]["agentDeliveryContinuation"], continuation,
        "reconstruction must retain the same provenance that live clients saw"
    );
}

#[tokio::test]
async fn emit_turn_start_advances_stale_sequence_counter_from_db() {
    let mut h = harness();
    let inserted = h
        .store
        .append(&AppendOptions {
            session_id: &h.session_id,
            event_type: EventType::MessageUser,
            payload: json!({"content": "preexisting"}),
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
        None,
        Some(&h.counter),
        None,
        None,
    )
    .unwrap();

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
async fn emit_turn_start_allocates_after_live_runtime_events() {
    let mut h = harness();
    h.counter.store(5, Ordering::SeqCst);

    emit_turn_start(
        &h.emitter,
        Some(&h.persister),
        &h.session_id,
        1,
        None,
        Some(&h.counter),
        None,
        None,
    )
    .unwrap();

    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
        .await
        .expect("broadcast should arrive")
        .expect("broadcast channel alive");
    let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_start");
    assert_eq!(persisted, vec![6]);
    assert_eq!(broadcast.sequence(), Some(6));
    assert_eq!(h.counter.load(Ordering::SeqCst), 6);
}

#[tokio::test]
async fn emit_turn_start_without_persister_still_broadcasts() {
    // When no persister is configured (pure live emit, used by some test
    // harnesses), the function must still broadcast — no regression for
    // emitter-only callers.
    let mut h = harness();

    emit_turn_start(
        &h.emitter,
        None,
        &h.session_id,
        1,
        None,
        Some(&h.counter),
        None,
        None,
    )
    .unwrap();

    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
        .await
        .expect("broadcast should arrive")
        .expect("broadcast channel alive");
    assert_eq!(broadcast.event_type(), "turn_start");
}

#[tokio::test]
async fn emit_turn_start_skips_broadcast_on_persist_failure() {
    let mut h = harness();

    let persist_result = emit_turn_start(
        &h.emitter,
        Some(&h.persister),
        "missing-session",
        1,
        None,
        Some(&h.counter),
        None,
        None,
    );
    assert!(persist_result.is_err());

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
        tool_invocations: Vec::new(),
        interrupted: false,
        partial_content: None,
        ttft_ms: None,
    }
}

#[tokio::test]
async fn tool_batch_redacts_arguments_before_live_broadcast() {
    let mut h = harness();
    let token = "trwh_0123456789abcdef0123456789abcdef";
    let invocation = ToolInvocationDraft::new(
        "call-secret",
        "worker_webhook_rotate",
        serde_json::Map::from_iter([
            ("token".to_owned(), json!(token)),
            ("workerId".to_owned(), json!("recent-research")),
        ]),
    );

    emit_tool_invocation_batch(
        &h.emitter,
        &h.session_id,
        &[invocation],
        Some(&h.counter),
        None,
        None,
    );

    let event = h.rx.recv().await.expect("tool batch broadcast");
    let TronEvent::ToolInvocationBatch {
        tool_invocations, ..
    } = event
    else {
        panic!("expected tool invocation batch");
    };
    assert_eq!(tool_invocations[0].arguments["token"], "****");
    assert_eq!(tool_invocations[0].arguments["workerId"], "recent-research");
    assert!(
        !serde_json::to_string(&tool_invocations)
            .unwrap()
            .contains(token)
    );
}

#[tokio::test]
async fn emit_turn_end_persists_before_broadcasting() {
    let mut h = harness();
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
        Some("assignment_usage_a"),
    )
    .unwrap();

    let broadcast = tokio::time::timeout(std::time::Duration::from_secs(2), h.rx.recv())
        .await
        .expect("broadcast should arrive")
        .expect("broadcast channel alive");
    let broadcast_seq = broadcast.sequence().expect("sequenced event");

    let persisted = persisted_events(&h.store, &h.session_id, "stream.turn_end");
    let payloads = persisted_payloads(&h.store, &h.session_id, "stream.turn_end");

    assert_eq!(persisted.len(), 1);
    assert!(
        payloads[0].get("tokenUsage").is_none(),
        "turn_end without provider usage must not persist synthetic zero-token usage"
    );
    assert_eq!(
        payloads[0]["agentAssignmentId"], "assignment_usage_a",
        "reusable-agent usage must carry its exact durable assignment identity"
    );
    assert_eq!(payloads[0]["latency"], 42);
    assert_eq!(
        persisted[0], broadcast_seq,
        "durable and live turn end must share one sequence"
    );
}

#[tokio::test]
async fn emit_turn_end_skips_broadcast_on_persist_failure() {
    let mut h = harness();
    let stream = stream_result_stub();

    let error = emit_turn_end(
        &h.emitter,
        Some(&h.persister),
        "missing-session",
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
        None,
    )
    .expect_err("turn-end persistence failure must propagate");
    assert!(error.to_string().contains("missing-session"));

    let result = tokio::time::timeout(std::time::Duration::from_millis(100), h.rx.recv()).await;
    assert!(
        result.is_err(),
        "no broadcast should fire when persist fails, got: {result:?}"
    );
}

// ── Persist-before-broadcast: response-complete events ─────────────────

#[test]
fn persist_completed_assistant_message_returns_ok_on_success() {
    let h = harness();
    let payload = json!({ "content": [], "turn": 1 });
    let result = persist_completed_assistant_message(
        Some(&h.persister),
        &h.session_id,
        payload,
        Some(&h.counter),
    );
    assert!(result.is_ok());
}

#[test]
fn persist_completed_assistant_message_returns_err_on_store_failure() {
    let h = harness();
    let payload = json!({ "content": [], "turn": 1 });
    let result = persist_completed_assistant_message(
        Some(&h.persister),
        "missing-session",
        payload,
        Some(&h.counter),
    );
    assert!(result.is_err(), "persist must surface event-store errors");
}

#[test]
fn persist_completed_assistant_message_allows_no_persister_callers() {
    // Callers that pass None (tests, pure-live-emit contexts) must get
    // Ok so they proceed to emit ResponseComplete — no persister, no
    // failure mode to guard against.
    let h = harness();
    let payload = json!({ "content": [], "turn": 1 });
    let result =
        persist_completed_assistant_message(None, &h.session_id, payload, Some(&h.counter));
    assert!(result.is_ok());
}
