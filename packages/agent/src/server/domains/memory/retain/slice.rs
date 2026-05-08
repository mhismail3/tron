//! Event-store slicing for memory retain.

use crate::events::types::state::Message;
use crate::events::{EventStore, event_rows_to_session_events, reconstruct_from_events};
use crate::server::shared::error_mapping::map_event_store_error;
use crate::server::shared::errors::CapabilityError;

/// Find the sequence number to use as the "start of window" for summarization.
///
/// Priority:
/// 1. Latest `memory.retained` event (previous retain boundary)
/// 2. Latest `compact.boundary` event (compaction boundary)
/// 3. 0 (beginning of session)
pub(super) fn find_boundary_sequence(
    store: &EventStore,
    session_id: &str,
) -> Result<i64, CapabilityError> {
    if let Ok(Some(row)) = store.get_latest_event_by_type(session_id, "memory.retained") {
        return Ok(row.sequence);
    }
    if let Ok(Some(row)) = store.get_latest_event_by_type(session_id, "compact.boundary") {
        return Ok(row.sequence);
    }
    Ok(0)
}

/// The slice of events after the last retain boundary, along with the ISO
/// timestamps of the first and last event in the slice.
pub(super) struct RetainSlice {
    pub(super) messages: Vec<Message>,
    pub(super) start_ts: String,
    pub(super) end_ts: String,
}

/// Reconstruct messages since `after_sequence` and capture the first/last
/// event timestamps from the raw rows before they are collapsed.
pub(super) fn get_retain_slice(
    store: &EventStore,
    session_id: &str,
    after_sequence: i64,
) -> Result<Option<RetainSlice>, CapabilityError> {
    let rows = store
        .get_events_since(session_id, after_sequence)
        .map_err(map_event_store_error)?;

    if rows.is_empty() {
        return Ok(None);
    }

    let start_ts = rows
        .first()
        .map(|r| r.timestamp.clone())
        .unwrap_or_default();
    let end_ts = rows.last().map(|r| r.timestamp.clone()).unwrap_or_default();

    let events = event_rows_to_session_events(&rows);
    let result = reconstruct_from_events(&events);
    let messages = result
        .messages_with_event_ids
        .into_iter()
        .map(|m| m.message)
        .collect();

    Ok(Some(RetainSlice {
        messages,
        start_ts,
        end_ts,
    }))
}
