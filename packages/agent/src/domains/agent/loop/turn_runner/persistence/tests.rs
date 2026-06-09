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
async fn persist_completed_assistant_message_allows_no_persister_callers() {
    // Callers that pass None (tests, pure-live-emit contexts) must get
    // Ok so they proceed to emit ResponseComplete — no persister, no
    // failure mode to guard against.
    let h = harness().await;
    let payload = json!({ "content": [], "turn": 1 });
    let result =
        persist_completed_assistant_message(None, &h.session_id, payload, Some(&h.counter)).await;
    assert!(result.is_ok());
}
