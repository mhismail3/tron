use serde_json::Value;

use crate::events::errors::{EventStoreError, Result};
use crate::events::reconstruct::{ReconstructionResult, reconstruct_from_events};
use crate::events::sqlite::repositories::event::EventRepo;
use crate::events::sqlite::repositories::session::SessionRepo;
use crate::events::sqlite::row_types::{EventRow, SessionRow};
use crate::events::types::EventType;
use crate::events::types::base::SessionEvent;
use crate::events::types::state::SessionState;

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
        let events = event_rows_to_session_events(&ancestors);
        Ok(reconstruct_from_events(&events))
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
        let events = event_rows_to_session_events(&ancestors);
        Ok(reconstruct_from_events(&events))
    }

    /// Build full session state at the head event.
    ///
    /// Combines session metadata with reconstructed messages.
    pub fn get_state_at_head(&self, session_id: &str) -> Result<SessionState> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let head_id = session
            .head_event_id
            .as_deref()
            .ok_or_else(|| EventStoreError::InvalidOperation("Session has no head event".into()))?;
        let ancestors = EventRepo::get_ancestors(&conn, head_id)?;
        let events = event_rows_to_session_events(&ancestors);
        let reconstruction = reconstruct_from_events(&events);
        Ok(build_session_state(&session, head_id, reconstruction))
    }

    /// Build full session state at a specific event.
    pub fn get_state_at(&self, session_id: &str, event_id: &str) -> Result<SessionState> {
        let conn = self.conn()?;
        let session = SessionRepo::get_by_id(&conn, session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_string()))?;
        let ancestors = EventRepo::get_ancestors(&conn, event_id)?;
        if ancestors.is_empty() {
            return Err(EventStoreError::EventNotFound(event_id.to_string()));
        }
        let events = event_rows_to_session_events(&ancestors);
        let reconstruction = reconstruct_from_events(&events);
        Ok(build_session_state(&session, event_id, reconstruction))
    }
}

/// Convert `EventRow`s to `SessionEvent`s for reconstruction.
///
/// Each `EventRow.payload` is a JSON string; this parses it into `serde_json::Value`.
/// Invalid JSON falls back to `Value::Null`.
pub fn event_rows_to_session_events(rows: &[EventRow]) -> Vec<SessionEvent> {
    rows.iter()
        .map(|row| SessionEvent {
            id: row.id.clone(),
            parent_id: row.parent_id.clone(),
            session_id: row.session_id.clone(),
            workspace_id: row.workspace_id.clone(),
            timestamp: row.timestamp.clone(),
            event_type: row.event_type.parse().unwrap_or(EventType::SessionStart),
            sequence: row.sequence,
            checksum: row.checksum.clone(),
            payload: serde_json::from_str(&row.payload).unwrap_or_else(|error| {
                tracing::warn!(
                    event_id = %row.id,
                    error = %error,
                    "corrupt event payload, defaulting to null"
                );
                Value::Null
            }),
        })
        .collect()
}

pub(super) fn build_session_state(
    session: &SessionRow,
    head_event_id: &str,
    reconstruction: ReconstructionResult,
) -> SessionState {
    use crate::events::types::payloads::TokenUsage;

    SessionState {
        session_id: session.id.clone(),
        workspace_id: session.workspace_id.clone(),
        head_event_id: head_event_id.to_string(),
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
        provider: None,
        system_prompt: reconstruction.system_prompt,
        reasoning_level: reconstruction.reasoning_level,
        metadata: None,
        is_ended: session.ended_at.as_ref().map(|_| true),
        branch: None,
        timestamp: Some(session.last_activity_at.clone()),
    }
}
