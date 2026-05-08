use super::decision::{RETAINED_TYPE, USER_MESSAGE_TYPE};
use super::*;

// ─────────────────────────────────────────────────────────────────────────────
// State gathering (sync, testable)
// ─────────────────────────────────────────────────────────────────────────────

/// Read the event store to build the inputs for [`should_auto_retain`].
///
/// Blocking: hits SQLite. Must be called from a blocking context
/// (e.g. wrapped in `run_blocking` from an async caller).
///
/// The "since last retain" count is derived from the sequence of the most
/// recent `memory.retained` event (0 if none) — the retain event itself is
/// the boundary, so no `turn_number` field needs to live on its payload.
pub fn gather_state(
    event_store: &EventStore,
    session_id: &str,
    interval: u32,
) -> Result<AutoRetainInput, CapabilityError> {
    let session = event_store
        .get_session(session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: SESSION_NOT_FOUND.into(),
            message: format!("session {session_id} not found"),
        })?;

    let last_retained_sequence = event_store
        .get_latest_event_by_type(session_id, RETAINED_TYPE)
        .map_err(map_event_store_error)?
        .map(|row| row.sequence)
        .unwrap_or(0);

    let user_messages_since_retain = event_store
        .count_events_by_type_after_sequence(session_id, USER_MESSAGE_TYPE, last_retained_sequence)
        .map_err(map_event_store_error)?;

    Ok(AutoRetainInput {
        interval,
        user_messages_since_retain,
        is_subagent: session.parent_session_id.is_some(),
    })
}
