//! Agent event persistence with runtime sequence reconciliation.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use serde_json::Value;

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::session::event_store::{AppendOptions, EventRow, EventStore, EventType};

/// Agent-owned facade over the authoritative session event store.
///
/// `EventStore` owns transactional per-session write serialization and parent
/// threading. This facade only reconciles the live runtime sequence counter
/// before writes that must share a sequence with their broadcast event.
pub struct EventPersister {
    event_store: Arc<EventStore>,
}

impl EventPersister {
    pub(crate) fn new(event_store: Arc<EventStore>) -> Self {
        Self { event_store }
    }

    /// Persist an event through the event store's per-session transaction.
    pub(crate) fn append(
        &self,
        session_id: &str,
        event_type: EventType,
        payload: Value,
    ) -> Result<EventRow, RuntimeError> {
        self.append_with_sequence(session_id, event_type, payload, None)
    }

    /// Persist an event whose live runtime has a shared sequence counter.
    ///
    /// Runtime turns mostly pre-assign sequence numbers so persisted rows and
    /// live broadcasts stay ordered. Before reserving a runtime sequence, sync
    /// the counter to DB truth; if another writer wins the same slot between
    /// sync and append, retry from the new DB max instead of failing the turn
    /// with a `(session_id, sequence)` collision.
    pub(crate) fn append_with_runtime_sequence(
        &self,
        session_id: &str,
        event_type: EventType,
        payload: Value,
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<EventRow, RuntimeError> {
        let Some(counter) = sequence_counter else {
            return self.append(session_id, event_type, payload);
        };

        let mut last_error = None;
        for _ in 0..3 {
            self.advance_counter_to_db_max(session_id, counter)?;
            let sequence = counter.fetch_add(1, Ordering::SeqCst) + 1;
            match self.append_with_sequence(session_id, event_type, payload.clone(), Some(sequence))
            {
                Ok(row) => {
                    advance_counter_at_least(counter, row.sequence);
                    return Ok(row);
                }
                Err(error) if is_sequence_collision(&error) => {
                    last_error = Some(error);
                }
                Err(error) => return Err(error),
            }
        }

        Err(last_error.unwrap_or_else(|| {
            RuntimeError::Persistence("sequence allocation retry exhausted".to_owned())
        }))
    }

    fn append_with_sequence(
        &self,
        session_id: &str,
        event_type: EventType,
        payload: Value,
        sequence: Option<i64>,
    ) -> Result<EventRow, RuntimeError> {
        self.event_store
            .append(&AppendOptions {
                session_id,
                event_type,
                payload,
                parent_id: None,
                sequence,
            })
            .map_err(|error| RuntimeError::Persistence(error.to_string()))
    }

    fn advance_counter_to_db_max(
        &self,
        session_id: &str,
        counter: &AtomicI64,
    ) -> Result<(), RuntimeError> {
        let floor = self
            .event_store
            .get_max_sequence(session_id)
            .map_err(|error| RuntimeError::Persistence(error.to_string()))?;
        advance_counter_at_least(counter, floor);
        Ok(())
    }
}

fn advance_counter_at_least(counter: &AtomicI64, floor: i64) {
    let mut current = counter.load(Ordering::SeqCst);
    while current < floor {
        match counter.compare_exchange(current, floor, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => break,
            Err(next) => current = next,
        }
    }
}

fn is_sequence_collision(error: &RuntimeError) -> bool {
    let RuntimeError::Persistence(message) = error else {
        return false;
    };
    message.contains("UNIQUE constraint failed: events.session_id, events.sequence")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_event_store() -> Arc<EventStore> {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .expect("Failed to create in-memory pool");
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[test]
    fn append_and_retrieve() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .expect("Failed to create session");
        let persister = EventPersister::new(store);

        let event = persister
            .append(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "hello"}),
            )
            .unwrap();

        assert_eq!(event.session_id, session.session.id);
    }

    #[test]
    fn sequential_events_form_parent_chain() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .expect("Failed to create session");
        let persister = EventPersister::new(store);
        let sid = &session.session.id;

        let first = persister
            .append(
                sid,
                EventType::MessageUser,
                serde_json::json!({"content": "a"}),
            )
            .unwrap();
        let second = persister
            .append(
                sid,
                EventType::MessageAssistant,
                serde_json::json!({"content": "b"}),
            )
            .unwrap();

        assert_eq!(second.parent_id.as_deref(), Some(first.id.as_str()));
    }

    #[test]
    fn storage_failure_is_mapped() {
        let persister = EventPersister::new(make_event_store());

        let error = persister
            .append(
                "missing-session",
                EventType::MessageUser,
                serde_json::json!({"content": "hello"}),
            )
            .unwrap_err();

        assert!(matches!(error, RuntimeError::Persistence(_)));
        assert!(error.to_string().contains("session not found"));
    }

    #[test]
    fn append_with_preassigned_sequence() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .expect("Failed to create session");
        let persister = EventPersister::new(store);

        let event = persister
            .append_with_sequence(
                &session.session.id,
                EventType::MessageUser,
                serde_json::json!({"content": "hello"}),
                Some(42),
            )
            .unwrap();

        assert_eq!(event.sequence, 42);
    }

    #[test]
    fn runtime_sequence_syncs_after_direct_auto_append() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .expect("Failed to create session");
        let persister = EventPersister::new(store.clone());
        let sid = &session.session.id;
        let counter = AtomicI64::new(0);

        let direct = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MetadataUpdate,
                payload: serde_json::json!({"key": "title", "newValue": "test"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        assert_eq!(direct.sequence, 1);

        let event = persister
            .append_with_runtime_sequence(
                sid,
                EventType::MessageAssistant,
                serde_json::json!({"content": []}),
                Some(&counter),
            )
            .unwrap();

        assert_eq!(event.sequence, 2);
        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }
}
