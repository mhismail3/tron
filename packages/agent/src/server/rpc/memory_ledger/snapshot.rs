use crate::core::messages::{Message, UserMessageContent};
use crate::events::sqlite::row_types::EventRow;
use crate::events::types::payloads::memory::MemoryLedgerPayload;

/// Messages and metadata for the current ledger cycle.
pub struct CycleSnapshot {
    /// Messages in the cycle after the most recent ledger boundary.
    pub messages: Vec<Message>,
    /// First event ID covered by this cycle.
    pub first_event_id: String,
    /// Last event ID covered by this cycle.
    pub last_event_id: String,
    /// First user turn covered by this cycle.
    pub first_turn: i64,
    /// Last user turn covered by this cycle.
    pub last_turn: i64,
}

/// Build the message cycle since the latest `memory.ledger` boundary.
pub fn build_cycle_snapshot(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> Result<Option<CycleSnapshot>, crate::events::EventStoreError> {
    let boundary = event_store.get_latest_event_by_type(session_id, "memory.ledger")?;

    let (cycle_events, prior_turns) = if let Some(boundary_event) = boundary {
        let payload = serde_json::from_str::<MemoryLedgerPayload>(&boundary_event.payload)
            .unwrap_or_default();
        (
            event_store.get_events_since(session_id, boundary_event.sequence)?,
            payload.turn_range.last_turn,
        )
    } else {
        (
            event_store.get_events_by_session(
                session_id,
                &crate::events::sqlite::repositories::event::ListEventsOptions {
                    limit: None,
                    offset: None,
                },
            )?,
            0,
        )
    };

    if cycle_events.is_empty() {
        return Ok(None);
    }

    let messages = reconstruct_core_messages(&cycle_events);
    if messages.is_empty() {
        return Ok(None);
    }

    #[allow(clippy::cast_possible_wrap)]
    let user_turns_in_cycle = messages.iter().filter(|message| message.is_user()).count() as i64;
    if user_turns_in_cycle == 0 {
        return Ok(None);
    }

    let first_event_id = cycle_events
        .first()
        .map(|event| event.id.clone())
        .unwrap_or_default();
    let last_event_id = cycle_events
        .last()
        .map(|event| event.id.clone())
        .unwrap_or_default();

    Ok(Some(CycleSnapshot {
        messages,
        first_event_id,
        last_event_id,
        first_turn: prior_turns + 1,
        last_turn: prior_turns + user_turns_in_cycle,
    }))
}

fn reconstruct_core_messages(rows: &[EventRow]) -> Vec<Message> {
    let events = crate::events::event_rows_to_session_events(rows);
    crate::events::reconstruct_from_events(&events)
        .messages_with_event_ids
        .into_iter()
        .filter_map(|message| {
            serde_json::to_value(message.message)
                .ok()
                .and_then(|json| serde_json::from_value(json).ok())
        })
        .collect()
}

/// Prepare transcript for a cron session by stripping long boilerplate user prompts.
pub fn prepare_cron_transcript(messages: &[Message]) -> Vec<Message> {
    messages
        .iter()
        .map(|message| {
            if let Message::User { content, .. } = message
                && user_message_len(content) > 500
            {
                return Message::User {
                    content: UserMessageContent::Text(
                        "[Recurring cron task prompt omitted — focus on the assistant's actions below]".into(),
                    ),
                    timestamp: None,
                };
            }
            message.clone()
        })
        .collect()
}

/// Total text length across all assistant messages.
pub fn cron_assistant_text_len(messages: &[Message]) -> usize {
    messages
        .iter()
        .map(|message| {
            if let Message::Assistant { content, .. } = message {
                content
                    .iter()
                    .filter_map(|block| block.as_text())
                    .map(str::len)
                    .sum::<usize>()
            } else {
                0
            }
        })
        .sum()
}

pub(crate) fn user_message_len(content: &UserMessageContent) -> usize {
    match content {
        UserMessageContent::Text(text) => text.len(),
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| block.as_text())
            .map(str::len)
            .sum(),
    }
}
