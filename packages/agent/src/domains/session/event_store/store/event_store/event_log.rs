use rusqlite::OptionalExtension;
use serde_json::Value;

use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::identity::EventIdentity;
use crate::domains::session::event_store::sqlite::repositories::event::{
    EventRepo, ListEventsOptions,
};
use crate::domains::session::event_store::sqlite::repositories::session::{
    IncrementCounters, SessionRepo,
};
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::TokenTotals;
use crate::domains::session::event_store::types::base::SessionEvent;
use crate::domains::session::event_store::{EventRow, SessionRow};
use crate::shared::foundation::redaction::redact_sensitive_json;

use super::{AppendBatchItem, AppendOptions, EventStore};

fn resolve_payload_for_row(conn: &rusqlite::Connection, row: &EventRow) -> Result<Value> {
    crate::shared::storage::resolve_stored_json_value(conn, &row.payload).map_err(|error| {
        EventStoreError::Internal(format!(
            "failed to resolve stored payload for event {}: {error:#}",
            row.id
        ))
    })
}

/// Append a single event with an explicit durable identity.
///
/// This is the core write primitive used by [`EventStore::append`] and
/// [`EventStore::append_with_identity`], which wrap it in per-session locking,
/// a transaction, and commit.
///
/// The caller is responsible for:
/// - acquiring any required locks before opening the transaction,
/// - committing or rolling back the transaction,
/// - keeping `session.head_event_id` fresh if performing a loop of appends
///   (set it to the returned event's id after each call).
pub(super) fn append_event_in_tx_with_identity(
    tx: &rusqlite::Transaction<'_>,
    session: &SessionRow,
    opts: &AppendOptions<'_>,
    identity: EventIdentity,
) -> Result<SessionEvent> {
    let parent_id = match opts.parent_id {
        Some(pid) => Some(pid.to_string()),
        None => session.head_event_id.clone(),
    };

    // INVARIANT: when `opts.sequence` is `None` (the default for most
    // callers), the sequence is allocated here via `SELECT MAX(sequence) +
    // 1` inside the open transaction. This is race-free because:
    //   1. `EventStore::append` holds the per-session in-process write
    //      lock (`with_session_write_lock`) for the entire read→insert
    //      critical section.
    //   2. C3's `AgentDbLock` flock on `tron.sqlite.lock` guarantees that only
    //      one `tron` process at a time has write access to this database,
    //      so no sibling daemon can allocate the same sequence.
    //   3. SQLite's `UNIQUE(session_id, sequence)` constraint acts as the
    //      final backstop: if a new path ever bypasses the invariants above
    //      and produces a duplicate, the insert fails loudly rather than
    //      silently corrupting the log.
    // Callers that want to pre-allocate (e.g. to attach a sequence to an
    // event before the transaction opens) can pass `Some(seq)` — no
    // correctness difference, purely an ergonomic choice.
    let sequence = match opts.sequence {
        Some(seq) => seq,
        None => {
            let max: Option<i64> = tx
                .query_row(
                    "SELECT MAX(sequence) FROM events WHERE session_id = ?1",
                    rusqlite::params![opts.session_id],
                    |row| row.get(0),
                )
                .optional()?
                .flatten();
            max.unwrap_or(0).checked_add(1).ok_or_else(|| {
                EventStoreError::InvalidOperation(format!(
                    "event sequence exhausted for session {}",
                    opts.session_id
                ))
            })?
        }
    };

    let payload = redact_sensitive_json(&opts.payload);

    let event = SessionEvent {
        id: identity.id,
        session_id: opts.session_id.to_string(),
        parent_id,
        workspace_id: session.workspace_id.clone(),
        timestamp: identity.timestamp,
        event_type: opts.event_type,
        sequence,
        checksum: None,
        payload,
    };

    EventRepo::insert(tx, &event)?;
    let _ = SessionRepo::update_head(tx, opts.session_id, &event.id)?;

    let mut counters = IncrementCounters {
        event_count: Some(1),
        ..Default::default()
    };

    if matches!(
        opts.event_type,
        EventType::MessageUser | EventType::MessageAssistant
    ) {
        counters.message_count = Some(1);
    }

    if opts.event_type == EventType::MessageAssistant {
        counters.turn_count = Some(1);
    }

    if opts.event_type == EventType::StreamTurnEnd {
        if let Some(tu) = opts.payload.get("tokenUsage") {
            counters.input_tokens = tu.get("inputTokens").and_then(Value::as_i64);
            counters.output_tokens = tu.get("outputTokens").and_then(Value::as_i64);
            counters.cache_read_tokens = tu.get("cacheReadTokens").and_then(Value::as_i64);
            counters.cache_creation_tokens = tu.get("cacheCreationTokens").and_then(Value::as_i64);
        }
        if let Some(cost) = opts.payload.get("cost").and_then(Value::as_f64) {
            counters.cost = Some(cost);
        }
    }

    if opts.event_type == EventType::MessageAssistant {
        counters.last_turn_input_tokens = opts
            .payload
            .get("tokenRecord")
            .and_then(|r| r.get("computed"))
            .and_then(|c| c.get("contextWindowTokens"))
            .and_then(Value::as_i64);
    }

    let _ = SessionRepo::increment_counters(tx, opts.session_id, &counters)?;
    Ok(event)
}

impl EventStore {
    /// Append an event to a session.
    ///
    /// Atomic: sequence generation, event insertion, head update, and counter
    /// increments all happen in a single transaction.
    #[tracing::instrument(skip(self, opts), fields(session_id = opts.session_id, event_type = %opts.event_type))]
    pub fn append(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        self.with_session_write_lock(opts.session_id, || self.append_inner(opts))
    }

    /// Append an event with an explicit ID and timestamp.
    ///
    /// Replay/import paths use this to avoid ambient entropy in durable event
    /// rows. Production callers should use [`Self::append`].
    #[tracing::instrument(skip(self, opts, identity), fields(session_id = opts.session_id, event_type = %opts.event_type))]
    pub fn append_with_identity(
        &self,
        opts: &AppendOptions<'_>,
        identity: EventIdentity,
    ) -> Result<EventRow> {
        self.with_session_write_lock(opts.session_id, || {
            self.append_inner_with_identity(opts, identity.clone())
        })
    }

    /// Inner append without acquiring the write lock.
    /// Called by `append` (which holds the lock) and by `delete_message`
    /// (which acquires the lock once at its own level).
    fn append_inner(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        self.append_inner_with_identity(opts, EventIdentity::generate_current())
    }

    /// Inner append with an explicit durable identity, without acquiring the write lock.
    fn append_inner_with_identity(
        &self,
        opts: &AppendOptions<'_>,
        identity: EventIdentity,
    ) -> Result<EventRow> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;

        let session = SessionRepo::get_by_id(&tx, opts.session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(opts.session_id.to_string()))?;

        let event = append_event_in_tx_with_identity(&tx, &session, opts, identity)?;
        tx.commit()?;

        EventRepo::get_by_id(&conn, &event.id)?.ok_or(EventStoreError::EventNotFound(event.id))
    }

    /// Append multiple events atomically while preserving their parent chain.
    pub(crate) fn append_batch(
        &self,
        session_id: &str,
        items: &[AppendBatchItem],
    ) -> Result<Vec<EventRow>> {
        if items.is_empty() {
            return Ok(Vec::new());
        }
        self.with_session_write_lock(session_id, || {
            let mut conn = self.conn()?;
            let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let mut session = SessionRepo::get_by_id(&tx, session_id)?
                .ok_or_else(|| EventStoreError::SessionNotFound(session_id.to_owned()))?;
            let mut event_ids = Vec::with_capacity(items.len());

            for item in items {
                let event = append_event_in_tx_with_identity(
                    &tx,
                    &session,
                    &AppendOptions {
                        session_id,
                        event_type: item.event_type,
                        payload: item.payload.clone(),
                        parent_id: None,
                        sequence: item.sequence,
                    },
                    EventIdentity::generate_current(),
                )?;
                session.head_event_id = Some(event.id.clone());
                event_ids.push(event.id);
            }

            tx.commit()?;
            event_ids
                .into_iter()
                .map(|event_id| {
                    EventRepo::get_by_id(&conn, &event_id)?
                        .ok_or(EventStoreError::EventNotFound(event_id))
                })
                .collect()
        })
    }

    /// Delete a message by appending a `message.deleted` event.
    ///
    /// The target event must be a message event (`message.user`, `message.assistant`,
    /// or `capability.invocation.completed`). The original event is never modified — deletion is recorded
    /// as a new event and applied during message reconstruction.
    #[tracing::instrument(skip(self), fields(session_id, target_event_id))]
    pub fn delete_message(
        &self,
        session_id: &str,
        target_event_id: &str,
        reason: Option<&str>,
    ) -> Result<EventRow> {
        self.with_session_write_lock(session_id, || {
            let conn = self.conn()?;
            let target = EventRepo::get_by_id(&conn, target_event_id)?
                .ok_or_else(|| EventStoreError::EventNotFound(target_event_id.to_string()))?;

            let target_type: EventType = target
                .event_type
                .parse()
                .map_err(|_| EventStoreError::InvalidOperation("Unknown event type".to_string()))?;

            if !matches!(
                target_type,
                EventType::MessageUser | EventType::MessageAssistant | EventType::CapabilityInvocationCompleted
            ) {
                return Err(EventStoreError::InvalidOperation(format!(
                    "Cannot delete event of type '{}' — only message and capability result events can be deleted",
                    target.event_type
                )));
            }

            self.append_inner(&AppendOptions {
                session_id,
                event_type: EventType::MessageDeleted,
                payload: serde_json::json!({
                    "targetEventId": target_event_id,
                    "targetType": target.event_type,
                    "reason": reason.unwrap_or("user_request"),
                }),
                parent_id: None,
                sequence: None,
            })
        })
    }

    /// Get a single event by ID.
    pub fn get_event(&self, event_id: &str) -> Result<Option<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_id(&conn, event_id)
    }

    /// Get all events for a session, ordered by sequence.
    pub fn get_events_by_session(
        &self,
        session_id: &str,
        opts: &ListEventsOptions,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_session(&conn, session_id, opts)
    }

    /// Get ancestor chain from root to the given event (inclusive).
    pub fn get_ancestors(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_ancestors(&conn, event_id)
    }

    /// Get direct children of an event.
    pub fn get_children(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_children(&conn, event_id)
    }

    /// Get all descendants of an event (recursive).
    pub fn get_descendants(&self, event_id: &str) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_descendants(&conn, event_id)
    }

    /// Get the current maximum sequence number for a session (0 if no events).
    pub fn get_max_sequence(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn()?;
        let max: Option<i64> = conn
            .query_row(
                "SELECT MAX(sequence) FROM events WHERE session_id = ?1",
                rusqlite::params![session_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        Ok(max.unwrap_or(0))
    }

    /// Get events inserted after a specific sequence number.
    pub fn get_events_since(&self, session_id: &str, after_sequence: i64) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_since(&conn, session_id, after_sequence)
    }

    /// Get the most recent N events for a session, in sequence ASC order.
    pub fn get_latest_events(&self, session_id: &str, limit: Option<i64>) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_latest_events(&conn, session_id, limit)
    }

    /// Resolve payloads for event rows returned to capability clients.
    ///
    /// Persisted event rows may store large JSON payloads out-of-line behind an
    /// internal `__tronPayloadRef` envelope. Active runtime APIs must expose the
    /// original canonical event payload so clients can reconstruct invocation
    /// state without blob-specific storage branches.
    pub fn resolve_event_payloads(&self, rows: &[EventRow]) -> Result<Vec<Value>> {
        let conn = self.conn()?;
        rows.iter()
            .map(|row| resolve_payload_for_row(&conn, row))
            .collect()
    }

    /// Get events with sequence < `before_sequence`, in sequence ASC order.
    pub fn get_events_before(
        &self,
        session_id: &str,
        before_sequence: i64,
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_events_before(&conn, session_id, before_sequence, limit)
    }

    /// Check if events exist before a given sequence number.
    pub fn has_events_before(&self, session_id: &str, before_sequence: i64) -> Result<bool> {
        let conn = self.conn()?;
        EventRepo::has_events_before(&conn, session_id, before_sequence)
    }

    /// Get token usage summary for a session.
    pub fn get_token_usage_summary(&self, session_id: &str) -> Result<TokenTotals> {
        let conn = self.conn()?;
        EventRepo::get_token_usage_summary(&conn, session_id)
    }

    /// Get events of specific types within a session.
    pub fn get_events_by_type(
        &self,
        session_id: &str,
        types: &[&str],
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_types(&conn, session_id, types, limit)
    }

    /// Get the latest event of a specific type for one session-turn ordinal.
    pub(crate) fn get_latest_event_by_type_and_turn(
        &self,
        session_id: &str,
        event_type: EventType,
        turn: u32,
    ) -> Result<Option<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_latest_by_type_and_turn(
            &conn,
            session_id,
            event_type.as_str(),
            i64::from(turn),
        )
    }

    /// Get the greatest durable turn ordinal for one event type in a session.
    pub(crate) fn get_max_turn_by_type(
        &self,
        session_id: &str,
        event_type: EventType,
    ) -> Result<Option<u32>> {
        let conn = self.conn()?;
        EventRepo::get_max_turn_by_type(&conn, session_id, event_type.as_str())?.map_or(
            Ok(None),
            |turn| {
                u32::try_from(turn).map(Some).map_err(|_| {
                    EventStoreError::Internal(format!(
                        "invalid negative or oversized turn {turn} for {} in session {session_id}",
                        event_type.as_str()
                    ))
                })
            },
        )
    }

    /// Get latest durable turn starts that still lack a later terminal row.
    /// Called before the server accepts connections so no live turn can race
    /// this startup repair.
    pub(crate) fn get_unterminalized_turn_starts(&self) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_unterminalized_turn_starts(&conn)
    }

    /// Count total events in a session.
    pub fn count_events(&self, session_id: &str) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_by_session(&conn, session_id)
    }

    /// Check if a session was interrupted (last turn didn't complete).
    ///
    /// A session is considered interrupted if the last `message.assistant` event
    /// has a higher sequence than the last `stream.turn_end` event, meaning the
    /// turn started but never finished.
    pub fn was_session_interrupted(&self, session_id: &str) -> Result<bool> {
        let conn = self.conn()?;
        let last_assistant = EventRepo::get_latest_by_type(&conn, session_id, "message.assistant")?;
        let last_turn_end = EventRepo::get_latest_by_type(&conn, session_id, "stream.turn_end")?;

        match (last_assistant, last_turn_end) {
            (None, _) => Ok(false),
            (Some(_), None) => Ok(true),
            (Some(assistant), Some(turn_end)) => Ok(assistant.sequence > turn_end.sequence),
        }
    }
}
