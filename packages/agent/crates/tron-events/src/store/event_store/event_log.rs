use std::collections::HashMap;

use serde_json::Value;
use uuid::Uuid;

use crate::errors::{EventStoreError, Result};
use crate::sqlite::repositories::branch::BranchRepo;
use crate::sqlite::repositories::event::{EventRepo, ListEventsOptions, TokenUsageSummary};
use crate::sqlite::repositories::session::{IncrementCounters, SessionRepo};
use crate::sqlite::row_types::EventRow;
use crate::types::EventType;
use crate::types::base::SessionEvent;

use super::{AppendOptions, EventStore};

impl EventStore {
    /// Append an event to a session.
    ///
    /// Atomic: sequence generation, event insertion, head update, and counter
    /// increments all happen in a single transaction.
    #[tracing::instrument(skip(self, opts), fields(session_id = opts.session_id, event_type = %opts.event_type))]
    pub fn append(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        self.with_session_write_lock(opts.session_id, || self.append_inner(opts))
    }

    /// Inner append without acquiring the write lock.
    /// Called by `append` (which holds the lock) and by `delete_message`
    /// (which acquires the lock once at its own level).
    fn append_inner(&self, opts: &AppendOptions<'_>) -> Result<EventRow> {
        let conn = self.conn()?;
        let tx = conn.unchecked_transaction()?;

        let session = SessionRepo::get_by_id(&tx, opts.session_id)?
            .ok_or_else(|| EventStoreError::SessionNotFound(opts.session_id.to_string()))?;

        let parent_id = match opts.parent_id {
            Some(pid) => Some(pid.to_string()),
            None => session.head_event_id.clone(),
        };

        let sequence = EventRepo::get_next_sequence(&tx, opts.session_id)?;
        let event_id = format!("evt_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();

        let event = SessionEvent {
            id: event_id,
            session_id: opts.session_id.to_string(),
            parent_id,
            workspace_id: session.workspace_id.clone(),
            timestamp: now,
            event_type: opts.event_type,
            sequence,
            checksum: None,
            payload: opts.payload.clone(),
        };

        EventRepo::insert(&tx, &event)?;
        let _ = SessionRepo::update_head(&tx, opts.session_id, &event.id)?;

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
                counters.cache_creation_tokens =
                    tu.get("cacheCreationTokens").and_then(Value::as_i64);
            }
            if let Some(cost) = opts.payload.get("cost").and_then(Value::as_f64) {
                counters.cost = Some(cost);
            }
        }

        if opts.event_type == EventType::MessageAssistant
            && let Some(tu) = opts.payload.get("tokenUsage")
        {
            counters.last_turn_input_tokens = opts
                .payload
                .get("tokenRecord")
                .and_then(|r| r.get("computed"))
                .and_then(|c| c.get("contextWindowTokens"))
                .and_then(Value::as_i64)
                .or_else(|| tu.get("inputTokens").and_then(Value::as_i64));
        }

        let _ = SessionRepo::increment_counters(&tx, opts.session_id, &counters)?;
        tx.commit()?;

        let inserted = EventRepo::get_by_id(&conn, &event.id)?
            .ok_or(EventStoreError::EventNotFound(event.id))?;
        Ok(inserted)
    }

    /// Delete a message by appending a `message.deleted` event.
    ///
    /// The target event must be a message event (`message.user`, `message.assistant`,
    /// or `tool.result`). The original event is never modified — deletion is recorded
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
                EventType::MessageUser | EventType::MessageAssistant | EventType::ToolResult
            ) {
                return Err(EventStoreError::InvalidOperation(format!(
                    "Cannot delete event of type '{}' — only message and tool result events can be deleted",
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

    /// Get events inserted after a specific sequence number.
    pub fn get_events_since(&self, session_id: &str, after_sequence: i64) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_since(&conn, session_id, after_sequence)
    }

    /// Get token usage summary for a session.
    pub fn get_token_usage_summary(&self, session_id: &str) -> Result<TokenUsageSummary> {
        let conn = self.conn()?;
        EventRepo::get_token_usage_summary(&conn, session_id)
    }

    /// Batch-fetch events by IDs.
    ///
    /// Returns a map of `event_id → EventRow`. IDs that don't match any event
    /// are silently omitted.
    pub fn get_events_by_ids(&self, event_ids: &[&str]) -> Result<HashMap<String, EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_ids(&conn, event_ids)
    }

    /// Get events of specific types across multiple sessions.
    pub fn get_events_by_sessions_and_types(
        &self,
        session_ids: &[&str],
        types: &[&str],
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_sessions_and_types(&conn, session_ids, types)
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

    /// Get the latest event of a specific type within a session.
    pub fn get_latest_event_by_type(
        &self,
        session_id: &str,
        event_type: &str,
    ) -> Result<Option<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_latest_by_type(&conn, session_id, event_type)
    }

    /// Get events by workspace and types (cross-session query).
    pub fn get_events_by_workspace_and_types(
        &self,
        workspace_id: &str,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_workspace_and_types(&conn, workspace_id, types, limit, offset)
    }

    /// Count events by workspace and types.
    pub fn count_events_by_workspace_and_types(
        &self,
        workspace_id: &str,
        types: &[&str],
    ) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_by_workspace_and_types(&conn, workspace_id, types)
    }

    /// Get events across multiple workspaces by types.
    pub fn get_events_by_workspaces_and_types(
        &self,
        workspace_ids: &[&str],
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_by_workspaces_and_types(&conn, workspace_ids, types, limit, offset)
    }

    /// Count events across multiple workspaces by types.
    pub fn count_events_by_workspaces_and_types(
        &self,
        workspace_ids: &[&str],
        types: &[&str],
    ) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_by_workspaces_and_types(&conn, workspace_ids, types)
    }

    /// Get events of specific types across ALL workspaces (global query).
    pub fn get_all_events_by_types(
        &self,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let conn = self.conn()?;
        EventRepo::get_all_by_types(&conn, types, limit, offset)
    }

    /// Count events of specific types across ALL workspaces (global query).
    pub fn count_all_events_by_types(&self, types: &[&str]) -> Result<i64> {
        let conn = self.conn()?;
        EventRepo::count_all_by_types(&conn, types)
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

    /// Get branches for a session.
    pub fn get_branches(
        &self,
        session_id: &str,
    ) -> Result<Vec<crate::sqlite::row_types::BranchRow>> {
        let conn = self.conn()?;
        BranchRepo::get_by_session(&conn, session_id)
    }

    /// Get the active worktree for a session, if any.
    ///
    /// Returns the most recent `worktree.acquired` event if there is no
    /// subsequent `worktree.released` event (or the acquired event has a
    /// higher sequence number).
    pub fn get_active_worktree(&self, session_id: &str) -> Result<Option<EventRow>> {
        let acquired = self.get_events_by_type(session_id, &["worktree.acquired"], None)?;
        if acquired.is_empty() {
            return Ok(None);
        }

        let released = self.get_events_by_type(session_id, &["worktree.released"], None)?;

        let latest_acquired = acquired.last();
        let latest_released = released.last();

        match (latest_acquired, latest_released) {
            (Some(acq), None) => Ok(Some(acq.clone())),
            (Some(acq), Some(rel)) if acq.sequence > rel.sequence => Ok(Some(acq.clone())),
            _ => Ok(None),
        }
    }
}
