//! Agent event persistence with runtime sequence reconciliation.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use serde_json::Value;

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::session::event_store::{
    AppendBatchItem, AppendOptions, EventRow, EventStore, EventType,
};

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
            let sequence = reserve_sequence_range(counter, 1)?;
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

    /// Atomically persist a lifecycle batch with consecutive runtime sequences.
    pub(crate) fn append_batch_with_runtime_sequence(
        &self,
        session_id: &str,
        events: &[(EventType, Value)],
        sequence_counter: Option<&AtomicI64>,
    ) -> Result<Vec<EventRow>, RuntimeError> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        let Some(counter) = sequence_counter else {
            let items = events
                .iter()
                .map(|(event_type, payload)| AppendBatchItem {
                    event_type: *event_type,
                    payload: payload.clone(),
                    sequence: None,
                })
                .collect::<Vec<_>>();
            return self
                .event_store
                .append_batch(session_id, &items)
                .map_err(|error| RuntimeError::Persistence(error.to_string()));
        };

        let count = i64::try_from(events.len()).map_err(|_| {
            RuntimeError::Persistence("event batch exceeds sequence capacity".to_owned())
        })?;
        let mut last_error = None;
        for _ in 0..3 {
            self.advance_counter_to_db_max(session_id, counter)?;
            let first_sequence = reserve_sequence_range(counter, count)?;
            let items = events
                .iter()
                .enumerate()
                .map(|(index, (event_type, payload))| {
                    let offset = i64::try_from(index).map_err(|_| {
                        RuntimeError::Persistence(
                            "event batch exceeds sequence capacity".to_owned(),
                        )
                    })?;
                    Ok(AppendBatchItem {
                        event_type: *event_type,
                        payload: payload.clone(),
                        sequence: Some(first_sequence + offset),
                    })
                })
                .collect::<Result<Vec<_>, RuntimeError>>()?;
            match self.event_store.append_batch(session_id, &items) {
                Ok(rows) => return Ok(rows),
                Err(error) => {
                    let error = RuntimeError::Persistence(error.to_string());
                    if is_sequence_collision(&error) {
                        last_error = Some(error);
                    } else {
                        return Err(error);
                    }
                }
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

fn reserve_sequence_range(counter: &AtomicI64, count: i64) -> Result<i64, RuntimeError> {
    let mut current = counter.load(Ordering::SeqCst);
    loop {
        let next = current.checked_add(count).ok_or_else(|| {
            RuntimeError::Persistence("runtime sequence ordinal exhausted".to_owned())
        })?;
        match counter.compare_exchange(current, next, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) => {
                return current.checked_add(1).ok_or_else(|| {
                    RuntimeError::Persistence("runtime sequence ordinal exhausted".to_owned())
                });
            }
            Err(observed) => current = observed,
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
    fn runtime_batch_rolls_back_every_event_when_terminal_append_fails() {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            crate::domains::session::event_store::run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_turn_failure
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'turn.failed'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced terminal failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        let before = store
            .get_session(&session.session.id)
            .unwrap()
            .expect("session exists");
        let persister = EventPersister::new(Arc::clone(&store));
        let counter = AtomicI64::new(store.get_max_sequence(&session.session.id).unwrap());

        let result = persister.append_batch_with_runtime_sequence(
            &session.session.id,
            &[
                (
                    EventType::MessageAssistant,
                    serde_json::json!({"turn": 1, "content": "partial"}),
                ),
                (
                    EventType::TurnFailed,
                    serde_json::json!({"turn": 1, "error": "cancelled"}),
                ),
            ],
            Some(&counter),
        );

        assert!(result.is_err());
        let rows = store
            .get_events_by_session(
                &session.session.id,
                &crate::domains::session::event_store::ListEventsOptions::default(),
            )
            .unwrap();
        assert!(rows.iter().all(|row| {
            row.event_type != EventType::MessageAssistant.as_str()
                && row.event_type != EventType::TurnFailed.as_str()
        }));
        let after = store
            .get_session(&session.session.id)
            .unwrap()
            .expect("session exists");
        assert_eq!(after.head_event_id, before.head_event_id);
        assert_eq!(after.event_count, before.event_count);
        assert_eq!(after.message_count, before.message_count);
        assert_eq!(after.turn_count, before.turn_count);
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

    #[test]
    fn exhausted_runtime_sequence_fails_without_wrapping_or_appending() {
        let store = make_event_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();
        let before = store.count_events(&session.session.id).unwrap();
        let persister = EventPersister::new(Arc::clone(&store));
        let counter = AtomicI64::new(i64::MAX);

        let error = persister
            .append_with_runtime_sequence(
                &session.session.id,
                EventType::MetadataUpdate,
                serde_json::json!({"key": "never"}),
                Some(&counter),
            )
            .expect_err("exhausted sequence must fail closed");

        assert!(error.to_string().contains("sequence ordinal exhausted"));
        assert_eq!(counter.load(Ordering::SeqCst), i64::MAX);
        assert_eq!(store.count_events(&session.session.id).unwrap(), before);
    }
}
