use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::types::RunContext;
use crate::domains::session::event_store::{EventRow, EventType};
use crate::shared::protocol::events::{BaseEvent, turn_failed_event};
use crate::shared::server::failure::FailureEnvelope;
use serde_json::{Value, json};
use tracing::warn;

fn run_base(session_id: &str, run_context: &RunContext) -> BaseEvent {
    BaseEvent::now(session_id).with_trace_context(
        run_context
            .engine_trace_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
        run_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
    )
}

fn turn_failure_payload(
    turn: u32,
    failure: &FailureEnvelope,
    partial_content: Option<&str>,
) -> Value {
    json!({
        "turn": turn,
        "error": failure.message,
        "code": failure.code,
        "category": failure.category.as_str(),
        "retryable": failure.retryable,
        "recoverable": failure.recoverable,
        "origin": failure.origin.as_str(),
        "details": failure.details_with_failure(),
        "partialContent": partial_content,
    })
}

fn emit_persisted_turn_failure(
    emitter: &EventEmitter,
    row: &EventRow,
    turn: u32,
    run_context: &RunContext,
    failure: &FailureEnvelope,
    partial_content: Option<String>,
) {
    let base = BaseEvent {
        session_id: row.session_id.clone(),
        timestamp: row.timestamp.clone(),
        sequence: Some(row.sequence),
        trace_id: run_context
            .engine_trace_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
        parent_invocation_id: run_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
    };
    let _ = emitter.emit(turn_failed_event(base, turn, failure, partial_content));
}

pub(super) fn terminalize_interrupted_turn(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    run_context: &RunContext,
    sequence_counter: Option<&AtomicI64>,
    failure: &FailureEnvelope,
    assistant_payload: Option<Value>,
    partial_content: Option<String>,
) -> Result<(), RuntimeError> {
    let Some(persister) = persister else {
        let event = turn_failed_event(
            run_base(session_id, run_context),
            turn,
            failure,
            partial_content,
        );
        if let Some(counter) = sequence_counter {
            let _ = emitter.emit_sequenced(event, counter);
        } else {
            let _ = emitter.emit(event);
        }
        return Ok(());
    };

    let mut events = Vec::with_capacity(usize::from(assistant_payload.is_some()) + 1);
    if let Some(payload) = assistant_payload {
        events.push((EventType::MessageAssistant, payload));
    }
    events.push((
        EventType::TurnFailed,
        turn_failure_payload(turn, failure, partial_content.as_deref()),
    ));
    let rows =
        persister.append_batch_with_runtime_sequence(session_id, &events, sequence_counter)?;
    let failure_row = rows.last().ok_or_else(|| {
        RuntimeError::Persistence("interrupted terminal batch produced no failure row".to_owned())
    })?;
    emit_persisted_turn_failure(
        emitter,
        failure_row,
        turn,
        run_context,
        failure,
        partial_content,
    );
    Ok(())
}

pub(super) fn emit_turn_failure(
    emitter: &Arc<EventEmitter>,
    persister: Option<&EventPersister>,
    session_id: &str,
    turn: u32,
    run_context: &RunContext,
    sequence_counter: Option<&AtomicI64>,
    failure: &FailureEnvelope,
    partial_content: Option<String>,
) -> bool {
    if let Some(persister) = persister {
        let payload = turn_failure_payload(turn, failure, partial_content.as_deref());
        let row = match persister.append_with_runtime_sequence(
            session_id,
            EventType::TurnFailed,
            payload,
            sequence_counter,
        ) {
            Ok(row) => row,
            Err(error) => {
                warn!(session_id, turn, error = %error, "failed to persist turn failure; skipping broadcast");
                return false;
            }
        };
        emit_persisted_turn_failure(emitter, &row, turn, run_context, failure, partial_content);
        return true;
    }

    let event = turn_failed_event(
        run_base(session_id, run_context),
        turn,
        failure,
        partial_content,
    );
    if let Some(counter) = sequence_counter {
        let _ = emitter.emit_sequenced(event, counter);
    } else {
        let _ = emitter.emit(event);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
    use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;
    use crate::domains::session::event_store::{EventStore, ListEventsOptions};
    use crate::shared::protocol::events::TronEvent;
    use crate::shared::server::failure::{FailureCategory, FailureOrigin, PROVIDER_API_ERROR};
    use std::sync::atomic::Ordering;

    #[tokio::test]
    async fn turn_failure_is_persisted_before_matching_sequence_is_broadcast() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        let emitter = Arc::new(EventEmitter::new());
        let mut receiver = emitter.subscribe();
        let persister = EventPersister::new(Arc::clone(&store));
        let counter = AtomicI64::new(0);
        let failure = FailureEnvelope::new(
            PROVIDER_API_ERROR,
            FailureCategory::Api,
            "provider failed",
            true,
            true,
            FailureOrigin::ModelProvider,
        )
        .with_provider_model("openai", "gpt-5.5");

        let persisted = emit_turn_failure(
            &emitter,
            Some(&persister),
            &session.session.id,
            4,
            &RunContext::default(),
            Some(&counter),
            &failure,
            Some("partial".into()),
        );

        assert!(persisted);

        let broadcast = receiver.recv().await.unwrap();
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap()
            .into_iter()
            .filter(|row| row.event_type == "turn.failed")
            .collect::<Vec<_>>();
        assert_eq!(rows.len(), 1);
        assert_eq!(broadcast.sequence(), Some(rows[0].sequence));
        assert_eq!(counter.load(Ordering::SeqCst), rows[0].sequence);

        let payload: serde_json::Value = serde_json::from_str(&rows[0].payload).unwrap();
        assert_eq!(payload["turn"], 4);
        assert_eq!(payload["code"], PROVIDER_API_ERROR);
        assert_eq!(payload["category"], "api");
        assert_eq!(payload["retryable"], true);
        assert_eq!(payload["recoverable"], true);
        assert_eq!(payload["partialContent"], "partial");
        assert_eq!(payload["details"]["failure"]["provider"], "openai");

        assert!(matches!(
            broadcast,
            TronEvent::TurnFailed {
                turn: 4,
                code: Some(code),
                retryable: Some(true),
                recoverable: true,
                partial_content: Some(partial),
                ..
            } if code == PROVIDER_API_ERROR && partial == "partial"
        ));
    }

    #[tokio::test]
    async fn turn_failure_is_not_broadcast_when_durable_write_fails() {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let emitter = Arc::new(EventEmitter::new());
        let mut receiver = emitter.subscribe();
        let persister = EventPersister::new(store);
        let counter = AtomicI64::new(0);
        let failure = FailureEnvelope::new(
            PROVIDER_API_ERROR,
            FailureCategory::Api,
            "provider failed",
            false,
            true,
            FailureOrigin::ModelProvider,
        );

        let persisted = emit_turn_failure(
            &emitter,
            Some(&persister),
            "missing-session",
            1,
            &RunContext::default(),
            Some(&counter),
            &failure,
            None,
        );

        assert!(!persisted);

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), receiver.recv())
                .await
                .is_err()
        );
    }
}
