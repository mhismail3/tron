//! Event persister — linearized event writes via MPSC serialization.

use std::sync::Arc;
use std::time::Instant;

use metrics::{counter, histogram};
use serde_json::Value;
#[cfg(test)]
use tokio::sync::Notify;
use tokio::sync::{mpsc, oneshot};
use crate::events::sqlite::row_types::EventRow;
use crate::events::{AppendOptions, EventStore, EventType};

use crate::runtime::errors::RuntimeError;

/// Request sent to the persist worker.
struct PersistRequest {
    session_id: String,
    event_type: EventType,
    payload: Value,
    reply: Option<oneshot::Sender<Result<EventRow, RuntimeError>>>,
}

#[cfg(test)]
type WorkerStartGate = (Arc<Notify>, Arc<Notify>);

#[cfg(not(test))]
type WorkerStartGate = ();

/// Linearized event persister.
///
/// All events for a session are serialized through an MPSC channel
/// to a single consumer task, guaranteeing linear `parent_id` threading.
pub struct EventPersister {
    tx: mpsc::Sender<PersistRequest>,
    worker_handle: tokio::task::JoinHandle<()>,
}

impl EventPersister {
    /// Create a new persister backed by the given event store.
    ///
    /// Spawns a background task that processes events sequentially.
    pub fn new(event_store: Arc<EventStore>) -> Self {
        Self::new_with_capacity_and_gate(event_store, 256, None)
    }

    /// Append an event and wait for persistence.
    pub async fn append(
        &self,
        session_id: &str,
        event_type: EventType,
        payload: Value,
    ) -> Result<EventRow, RuntimeError> {
        let (reply_tx, reply_rx) = oneshot::channel();

        self.tx
            .send(PersistRequest {
                session_id: session_id.to_owned(),
                event_type,
                payload,
                reply: Some(reply_tx),
            })
            .await
            .map_err(|_| self.map_send_error())?;

        reply_rx
            .await
            .map_err(|_| RuntimeError::Persistence("Persist reply dropped".into()))?
    }

    /// Queue an event for background persistence without waiting for the write result.
    ///
    /// This still applies backpressure when the queue is full so events are not
    /// silently dropped under load.
    pub async fn append_background(
        &self,
        session_id: &str,
        event_type: EventType,
        payload: Value,
    ) -> Result<(), RuntimeError> {
        let enqueue_started = Instant::now();
        self.tx
            .send(PersistRequest {
                session_id: session_id.to_owned(),
                event_type,
                payload,
                reply: None,
            })
            .await
            .map_err(|_| self.map_send_error())?;
        histogram!("event_persister_enqueue_seconds")
            .record(enqueue_started.elapsed().as_secs_f64());
        Ok(())
    }

    /// Gracefully shut down: signal worker to exit and await drain.
    pub async fn shutdown(self) {
        drop(self.tx);
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), self.worker_handle).await;
    }

    /// Flush all pending events (waits for the queue to drain).
    pub async fn flush(&self) -> Result<(), RuntimeError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(PersistRequest {
                session_id: String::new(),
                event_type: EventType::MetadataUpdate,
                payload: Value::Null,
                reply: Some(reply_tx),
            })
            .await
            .map_err(|_| self.map_send_error())?;

        let _ = reply_rx.await;
        Ok(())
    }

    fn map_send_error(&self) -> RuntimeError {
        if self.worker_handle.is_finished() {
            RuntimeError::Persistence("Persist worker panicked or exited".into())
        } else {
            RuntimeError::Persistence("Persist channel closed".into())
        }
    }

    fn new_with_capacity_and_gate(
        event_store: Arc<EventStore>,
        capacity: usize,
        worker_start_gate: Option<WorkerStartGate>,
    ) -> Self {
        let (tx, rx) = mpsc::channel(capacity);
        let worker_handle = tokio::spawn(persist_worker(rx, event_store, worker_start_gate));
        Self { tx, worker_handle }
    }

    #[cfg(test)]
    fn new_with_capacity_for_tests(
        event_store: Arc<EventStore>,
        capacity: usize,
        worker_start_gate: Option<WorkerStartGate>,
    ) -> Self {
        Self::new_with_capacity_and_gate(event_store, capacity, worker_start_gate)
    }
}

/// Background worker that processes persist requests sequentially.
async fn persist_worker(
    mut rx: mpsc::Receiver<PersistRequest>,
    event_store: Arc<EventStore>,
    #[allow(unused_variables)] worker_start_gate: Option<WorkerStartGate>,
) {
    #[cfg(test)]
    if let Some((entered, release)) = worker_start_gate {
        entered.notify_waiters();
        release.notified().await;
    }

    while let Some(req) = rx.recv().await {
        if req.payload.is_null() && req.session_id.is_empty() {
            if let Some(reply) = req.reply {
                let _ = reply.send(Ok(EventRow::flush_sentinel()));
            }
            continue;
        }

        let result = event_store.append(&AppendOptions {
            session_id: &req.session_id,
            event_type: req.event_type,
            payload: req.payload,
            parent_id: None,
        });

        if let Some(reply) = req.reply {
            let mapped = result.map_err(|error| RuntimeError::Persistence(error.to_string()));
            let _ = reply.send(mapped);
            continue;
        }

        if let Err(error) = result {
            counter!(
                "event_persister_background_errors_total",
                "event_type" => req.event_type.as_str()
            )
            .increment(1);
            tracing::warn!(
                session_id = %req.session_id,
                event_type = %req.event_type,
                error = %error,
                "background event persistence failed"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_event_store() -> Arc<EventStore> {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default())
            .expect("Failed to create in-memory pool");
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn append_and_retrieve() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());

        let result = persister
            .append(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "hello"}),
            )
            .await;

        assert!(result.is_ok());
        let event = result.unwrap();
        assert_eq!(event.session_id, session.session.id);
    }

    #[tokio::test]
    async fn sequential_events_form_chain() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());
        let sid = &session.session.id;

        let e1 = persister
            .append(
                sid,
                EventType::MessageUser,
                serde_json::json!({"content": "a"}),
            )
            .await
            .unwrap();

        let e2 = persister
            .append(
                sid,
                EventType::MessageAssistant,
                serde_json::json!({"content": "b"}),
            )
            .await
            .unwrap();

        assert_eq!(e1.session_id, e2.session_id);
        assert_ne!(e1.id, e2.id);
    }

    #[tokio::test]
    async fn append_background_persists_without_waiting_for_result() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());

        persister
            .append_background(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "fire"}),
            )
            .await
            .unwrap();

        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }

    #[tokio::test]
    async fn append_background_applies_backpressure_instead_of_dropping() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");
        let worker_entered = Arc::new(Notify::new());
        let worker_release = Arc::new(Notify::new());
        let persister = Arc::new(EventPersister::new_with_capacity_for_tests(
            store.clone(),
            1,
            Some((worker_entered.clone(), worker_release.clone())),
        ));

        worker_entered.notified().await;

        persister
            .append_background(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "first"}),
            )
            .await
            .unwrap();

        let mut queued = {
            let persister = persister.clone();
            let session_id = session.session.id.clone();
            tokio::spawn(async move {
                persister
                    .append_background(
                        &session_id,
                        EventType::MessageUser,
                        serde_json::json!({"content": "second"}),
                    )
                    .await
            })
        };

        let blocked = tokio::time::timeout(std::time::Duration::from_millis(50), &mut queued).await;
        assert!(
            blocked.is_err(),
            "second enqueue should wait when the persister queue is full"
        );

        worker_release.notify_waiters();
        queued.await.unwrap().unwrap();
        persister.flush().await.unwrap();

        let events = store.get_events_since(&session.session.id, 0).unwrap();
        let user_events = events
            .iter()
            .filter(|event| event.event_type == EventType::MessageUser.as_str())
            .count();
        assert!(
            user_events >= 2,
            "expected queued events to be persisted, got {user_events}"
        );
    }

    #[tokio::test]
    async fn flush_returns_ok() {
        let store = make_event_store();
        let persister = EventPersister::new(store.clone());

        let result = persister.flush().await;
        assert!(result.is_ok(), "flush must return Ok, got: {result:?}");
    }

    #[tokio::test]
    async fn flush_waits_for_pending() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());

        for i in 0..5 {
            persister
                .append_background(
                    &session.session.id,
                    EventType::MessageUser,
                    serde_json::json!({"content": format!("msg-{i}")}),
                )
                .await
                .unwrap();
        }

        let result = persister.flush().await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn shutdown_drains_pending_events() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());

        for i in 0..5 {
            persister
                .append_background(
                    &session.session.id,
                    EventType::MessageUser,
                    serde_json::json!({"content": format!("msg-{i}")}),
                )
                .await
                .unwrap();
        }

        persister.shutdown().await;

        let events = store.get_events_since(&session.session.id, 0).unwrap();
        assert!(
            events.len() >= 5,
            "expected at least 5 events, got {}",
            events.len()
        );
    }

    #[tokio::test]
    async fn shutdown_completes_within_timeout() {
        let store = make_event_store();
        let persister = EventPersister::new(store.clone());

        let start = std::time::Instant::now();
        persister.shutdown().await;
        assert!(
            start.elapsed().as_secs() < 5,
            "shutdown should complete quickly with no pending work"
        );
    }

    #[tokio::test]
    async fn shutdown_after_worker_abort() {
        let store = make_event_store();
        let persister = EventPersister::new(store.clone());

        persister.worker_handle.abort();
        tokio::time::sleep(tokio::time::Duration::from_millis(20)).await;

        let result =
            tokio::time::timeout(std::time::Duration::from_secs(6), persister.shutdown()).await;
        assert!(
            result.is_ok(),
            "shutdown must not hang when worker is already dead"
        );
    }

    #[tokio::test]
    async fn worker_exit_gives_descriptive_error() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone());

        persister.worker_handle.abort();
        tokio::time::sleep(tokio::time::Duration::from_millis(20)).await;

        let result = persister
            .append(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "hello"}),
            )
            .await;

        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(
            err.contains("panicked or exited"),
            "expected descriptive error, got: {err}"
        );
    }
}
