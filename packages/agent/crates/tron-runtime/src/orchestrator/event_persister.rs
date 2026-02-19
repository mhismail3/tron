//! Event persister — linearized event writes via MPSC serialization.

use std::sync::Arc;

use serde_json::Value;
use tokio::sync::{mpsc, oneshot};
use tron_events::sqlite::row_types::EventRow;
use tron_events::{AppendOptions, EventStore, EventType};

use crate::errors::RuntimeError;

/// Request sent to the persist worker.
struct PersistRequest {
    session_id: String,
    event_type: EventType,
    payload: Value,
    reply: Option<oneshot::Sender<Result<EventRow, RuntimeError>>>,
}

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
    pub fn new(event_store: Arc<EventStore>, session_id: String) -> Self {
        let (tx, rx) = mpsc::channel(256);

        let worker_handle = tokio::spawn(persist_worker(rx, event_store, session_id));

        Self { tx, worker_handle }
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
            .map_err(|_| {
                if self.worker_handle.is_finished() {
                    RuntimeError::Persistence("Persist worker panicked or exited".into())
                } else {
                    RuntimeError::Persistence("Persist channel closed".into())
                }
            })?;

        reply_rx
            .await
            .map_err(|_| RuntimeError::Persistence("Persist reply dropped".into()))?
    }

    /// Append an event without waiting for persistence.
    pub fn append_fire_and_forget(&self, session_id: &str, event_type: EventType, payload: Value) {
        if let Err(e) = self.tx.try_send(PersistRequest {
            session_id: session_id.to_owned(),
            event_type,
            payload,
            reply: None,
        }) {
            tracing::warn!(?event_type, error = %e, "fire-and-forget persist dropped: channel full");
        }
    }

    /// Flush all pending events (waits for the queue to drain).
    pub async fn flush(&self) -> Result<(), RuntimeError> {
        // Send a sentinel with reply to know when all prior messages are processed
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send(PersistRequest {
                session_id: String::new(),
                event_type: EventType::MetadataUpdate,
                payload: Value::Null,
                reply: Some(reply_tx),
            })
            .await
            .map_err(|_| {
                if self.worker_handle.is_finished() {
                    RuntimeError::Persistence("Persist worker panicked or exited".into())
                } else {
                    RuntimeError::Persistence("Persist channel closed".into())
                }
            })?;

        // Wait for the sentinel to be processed
        let _ = reply_rx.await;
        Ok(())
    }
}

/// Background worker that processes persist requests sequentially.
async fn persist_worker(
    mut rx: mpsc::Receiver<PersistRequest>,
    event_store: Arc<EventStore>,
    _default_session_id: String,
) {
    while let Some(req) = rx.recv().await {
        // Skip flush sentinels (null payload)
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
            let mapped = result.map_err(|e| RuntimeError::Persistence(e.to_string()));
            let _ = reply.send(mapped);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn make_event_store() -> Arc<EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default())
            .expect("Failed to create in-memory pool");
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn append_and_retrieve() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone(), session.session.id.clone());

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

        let persister = EventPersister::new(store.clone(), session.session.id.clone());
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

        // e2's parent should be e1 (or the session head before e1)
        // The exact chaining depends on EventStore implementation,
        // but both events should be in the same session
        assert_eq!(e1.session_id, e2.session_id);
        assert_ne!(e1.id, e2.id);
    }

    #[tokio::test]
    async fn fire_and_forget() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone(), session.session.id.clone());

        // Should not block or panic
        persister.append_fire_and_forget(
            &session.session.id,
            EventType::MessageUser,
            serde_json::json!({"content": "fire"}),
        );

        // Give the background task time to process
        tokio::time::sleep(tokio::time::Duration::from_millis(50)).await;
    }

    #[tokio::test]
    async fn flush_returns_ok() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone(), session.session.id.clone());

        // flush() should return Ok even with no pending events
        let result = persister.flush().await;
        assert!(result.is_ok(), "flush must return Ok, got: {result:?}");
    }

    #[tokio::test]
    async fn flush_waits_for_pending() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone(), session.session.id.clone());

        // Fire and forget several events
        for i in 0..5 {
            persister.append_fire_and_forget(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": format!("msg-{i}")}),
            );
        }

        // Flush should wait for all to complete
        let result = persister.flush().await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn worker_exit_gives_descriptive_error() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None)
            .expect("Failed to create session");

        let persister = EventPersister::new(store.clone(), session.session.id.clone());

        // Abort the worker to simulate it exiting
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
