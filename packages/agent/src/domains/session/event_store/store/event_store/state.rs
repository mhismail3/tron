use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::reconstruction::{
    ReconstructionResult, reconstruct_from_events,
};
use crate::domains::session::event_store::sqlite::repositories::event::EventRepo;
use crate::domains::session::event_store::sqlite::repositories::session::SessionRepo;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::base::SessionEvent;
use crate::domains::session::event_store::types::state::SessionState;
use crate::domains::session::event_store::{EventRow, SessionRow};

use super::EventStore;

impl EventStore {
    /// Reconstruct messages at the session head.
    ///
    /// Walks ancestors from root to head event, converts to `SessionEvent`s,
    /// and runs the two-pass reconstruction algorithm.
    pub fn get_messages_at_head(&self, session_id: &str) -> Result<ReconstructionResult> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let head_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| EventStoreError::InvalidOperation("Session has no head event".into()))?;
        let ancestors = EventRepo::get_ancestors(&conn, head_id)?;
        let events = event_rows_to_session_events(&conn, &ancestors)?;
        validated_reconstruction(&events)
    }

    /// Reconstruct messages at a specific event.
    ///
    /// Walks ancestors from root to the given event, converts to `SessionEvent`s,
    /// and runs the two-pass reconstruction algorithm.
    pub fn get_messages_at(&self, event_id: &str) -> Result<ReconstructionResult> {
        let conn = self.conn()?;
        let ancestors = EventRepo::get_ancestors(&conn, event_id)?;
        if ancestors.is_empty() {
            return Err(EventStoreError::EventNotFound(event_id.to_string()));
        }
        let events = event_rows_to_session_events(&conn, &ancestors)?;
        validated_reconstruction(&events)
    }

    /// Build the runtime session state at the head event.
    pub fn get_state_at_head(&self, session_id: &str) -> Result<SessionState> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let head_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| EventStoreError::InvalidOperation("Session has no head event".into()))?;
        let ancestors = EventRepo::get_ancestors(&conn, head_id)?;
        let events = event_rows_to_session_events(&conn, &ancestors)?;
        let reconstruction = validated_reconstruction(&events)?;
        Ok(build_session_state(&session, reconstruction))
    }
}

/// Convert persisted `EventRow`s to `SessionEvent`s for reconstruction.
///
/// Payloads are resolved through the owning SQLite connection so inline JSON
/// and blob-backed payload-ref envelopes follow the same storage path. Invalid
/// payloads and unknown event types fail reconstruction; silently omitting a
/// durable ancestor would let a provider continue with incomplete history.
///
/// Rows whose `event_type` string does not parse into a known [`EventType`] are
/// rejected as corrupt — they must never be silently reclassified or dropped.
pub(super) fn event_rows_to_session_events(
    conn: &rusqlite::Connection,
    rows: &[EventRow],
) -> Result<Vec<SessionEvent>> {
    rows.iter()
        .map(|row| {
            let event_type: EventType = row.event_type.parse().map_err(|error| {
                EventStoreError::InvalidOperation(format!(
                    "event {} has unknown type '{}': {error}",
                    row.id, row.event_type
                ))
            })?;
            let payload = crate::shared::storage::resolve_stored_json_value(conn, &row.payload)
                .map_err(|error| {
                    EventStoreError::Internal(format!(
                        "event {} payload could not be resolved: {error:#}",
                        row.id
                    ))
                })?;
            if event_type == EventType::ToolInvocationCompleted {
                validate_provider_history_payload(&row.id, event_type, &payload)?;
            }
            Ok(SessionEvent {
                id: row.id.clone(),
                parent_id: row.parent_id.clone(),
                session_id: row.session_id.clone(),
                workspace_id: row.workspace_id.clone(),
                timestamp: row.timestamp.clone(),
                event_type,
                sequence: row.sequence,
                checksum: row.checksum.clone(),
                payload,
            })
        })
        .collect()
}

/// Reconstruct provider history and validate only events that survive its
/// durable visibility rules.
///
/// `message.deleted` and `compact.boundary` can make older
/// message rows intentionally non-contributing. Message structural validation
/// therefore runs after reconstruction identifies surviving source event IDs,
/// but still validates every source row independently so same-role merging
/// cannot hide a malformed contributor. Tool completions retain their
/// unconditional row-conversion guard because malformed identity can itself
/// make a result appear unmatched and disappear from reconstruction.
fn validated_reconstruction(events: &[SessionEvent]) -> Result<ReconstructionResult> {
    let reconstruction = reconstruct_from_events(events);
    let contributing_event_ids = reconstruction
        .messages_with_event_ids
        .iter()
        .flat_map(|message| message.event_ids.iter().flatten())
        .map(String::as_str)
        .collect::<std::collections::HashSet<_>>();

    for event in events {
        if matches!(
            event.event_type,
            EventType::MessageUser | EventType::MessageAssistant
        ) && contributing_event_ids.contains(event.id.as_str())
        {
            validate_provider_history_payload(&event.id, event.event_type, &event.payload)?;
        }
    }

    Ok(reconstruction)
}

/// Reject malformed payloads that can contribute to a future provider request.
///
/// Full runtime-message decoding remains owned by the agent projection after
/// reconstruction has applied compaction and message merging. Tool
/// completions need a minimal check here because reconstruction can legitimately
/// discard an unmatched result; without it, a malformed completion could vanish
/// before the runtime projection sees it.
fn validate_provider_history_payload(
    event_id: &str,
    event_type: EventType,
    payload: &serde_json::Value,
) -> Result<()> {
    match event_type {
        EventType::MessageUser => {
            return validate_message_payload(event_id, "user", payload);
        }
        EventType::MessageAssistant => {
            return validate_message_payload(event_id, "assistant", payload);
        }
        EventType::ToolInvocationCompleted => {}
        _ => return Ok(()),
    }

    if payload
        .get("invocationId")
        .and_then(serde_json::Value::as_str)
        .filter(|id| !id.is_empty())
        .is_none()
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "event {event_id} has invalid tool completion payload: \
             invocationId must be a non-empty string"
        )));
    }

    match payload.get("modelContextContent") {
        Some(value) if !value.is_string() => {
            return Err(EventStoreError::InvalidOperation(format!(
                "event {event_id} has invalid tool completion payload: \
                 modelContextContent must be a string when present"
            )));
        }
        Some(_) => {}
        None if !payload
            .get("content")
            .is_some_and(serde_json::Value::is_string) =>
        {
            return Err(EventStoreError::InvalidOperation(format!(
                "event {event_id} has invalid tool completion payload: \
                 content must be a string"
            )));
        }
        None => {}
    }

    if !payload
        .get("isError")
        .is_some_and(serde_json::Value::is_boolean)
    {
        return Err(EventStoreError::InvalidOperation(format!(
            "event {event_id} has invalid tool completion payload: \
             isError must be a boolean"
        )));
    }

    Ok(())
}

fn validate_message_payload(
    event_id: &str,
    role: &'static str,
    payload: &serde_json::Value,
) -> Result<()> {
    let message = serde_json::json!({
        "role": role,
        "content": payload.get("content").cloned().unwrap_or(serde_json::Value::Null),
    });
    serde_json::from_value::<crate::shared::protocol::messages::Message>(message)
        .map(|_| ())
        .map_err(|error| {
            EventStoreError::InvalidOperation(format!(
                "event {event_id} has invalid message.{role} provider-history payload: {error}"
            ))
        })
}

pub(super) fn build_session_state(
    session: &SessionRow,
    reconstruction: ReconstructionResult,
) -> SessionState {
    use crate::domains::session::event_store::types::payloads::TokenUsage;

    SessionState {
        model: session.latest_model.clone(),
        working_directory: session.working_directory.clone(),
        messages_with_event_ids: reconstruction.messages_with_event_ids,
        token_usage: TokenUsage {
            input_tokens: session.total_input_tokens,
            output_tokens: session.total_output_tokens,
            cache_read_tokens: Some(session.total_cache_read_tokens),
            cache_creation_tokens: Some(session.total_cache_creation_tokens),
            ..Default::default()
        },
        turn_count: reconstruction.turn_count,
        is_ended: session.ended_at.as_ref().map(|_| true),
    }
}
