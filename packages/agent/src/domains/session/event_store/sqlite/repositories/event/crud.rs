use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;

use super::extractors::{
    extract_bool_as_int, extract_i64, extract_role, extract_str, extract_tokens, extract_tool_name,
};
use super::{EVENT_COLUMNS, EventRepo};
use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::types::SessionEvent;

impl EventRepo {
    /// Insert a single event, extracting denormalized fields from the payload.
    pub fn insert(conn: &Connection, event: &SessionEvent) -> Result<()> {
        let role = extract_role(event);
        let tool_name = extract_tool_name(event);
        let invocation_id = extract_str(&event.payload, "invocationId");
        let turn = extract_i64(&event.payload, "turn");
        let depth = Self::compute_depth(conn, event.parent_id.as_deref())?;

        // Extract token usage from payload.tokenUsage or payload directly
        let (input_tokens, output_tokens, cache_read, cache_create) =
            extract_tokens(&event.payload);

        // Extract current per-turn metadata.
        let model = extract_str(&event.payload, "model");
        let latency_ms = extract_i64(&event.payload, "latency");
        let stop_reason = extract_str(&event.payload, "stopReason");
        let has_thinking = extract_bool_as_int(&event.payload, "hasThinking");
        let provider_type = extract_str(&event.payload, "providerType");
        let cost = event.payload.get("cost").and_then(Value::as_f64);

        let payload_str = crate::shared::storage::store_json_value(
            conn,
            &event.payload,
            &crate::shared::storage::StorePayloadOptions::new(
                "session_event",
                event.id.clone(),
                "payload",
                "audit",
            )
            .with_scope(
                None,
                Some(event.session_id.clone()),
                Some(event.workspace_id.clone()),
            ),
        )
        .map_err(|error| {
            let message = format!("failed to store session event payload: {error:#}");
            if message.contains("database is locked")
                || message.contains("Cannot promote read transaction")
            {
                crate::domains::session::event_store::errors::EventStoreError::Busy {
                    operation: "session event payload storage",
                    attempts: 1,
                }
            } else {
                crate::domains::session::event_store::errors::EventStoreError::Internal(message)
            }
        })?;

        let sql = format!(
            "INSERT INTO events ({EVENT_COLUMNS})
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
                     ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25)"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let _ = stmt.execute(params![
            event.id,
            event.session_id,
            event.parent_id,
            event.sequence,
            depth,
            event.event_type.as_str(),
            event.timestamp,
            payload_str,
            Option::<String>::None, // content_blob_id
            event.workspace_id,
            role,
            tool_name,
            invocation_id,
            turn,
            input_tokens,
            output_tokens,
            cache_read,
            cache_create,
            event.checksum,
            model,
            latency_ms,
            stop_reason,
            has_thinking,
            provider_type,
            cost,
        ])?;
        Ok(())
    }

    /// Get a single event by ID.
    pub fn get_by_id(conn: &Connection, event_id: &str) -> Result<Option<EventRow>> {
        let sql = format!("SELECT {EVENT_COLUMNS} FROM events WHERE id = ?1");
        let mut stmt = conn.prepare_cached(&sql)?;
        let row = stmt
            .query_row(params![event_id], Self::map_row)
            .optional()?;
        Ok(row)
    }

    /// Get immutable source events by ID while enforcing session ownership.
    ///
    /// Context manifests can reference many source events. Reading them in
    /// bounded chunks avoids both N+1 queries and SQLite's parameter limit.
    pub(crate) fn get_by_ids_for_session(
        conn: &Connection,
        session_id: &str,
        event_ids: &[String],
    ) -> Result<Vec<EventRow>> {
        const QUERY_CHUNK_SIZE: usize = 500;

        if event_ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut rows = Vec::with_capacity(event_ids.len());
        for event_ids in event_ids.chunks(QUERY_CHUNK_SIZE) {
            let placeholders = (2..=event_ids.len() + 1)
                .map(|index| format!("?{index}"))
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT {EVENT_COLUMNS} FROM events \
                 WHERE session_id = ?1 AND id IN ({placeholders}) \
                 ORDER BY sequence ASC"
            );
            let mut parameters = Vec::with_capacity(event_ids.len() + 1);
            parameters.push(session_id.to_owned());
            parameters.extend(event_ids.iter().cloned());
            let mut statement = conn.prepare(&sql)?;
            rows.extend(
                statement
                    .query_map(rusqlite::params_from_iter(parameters.iter()), Self::map_row)?
                    .collect::<std::result::Result<Vec<_>, _>>()?,
            );
        }
        rows.sort_by_key(|row| row.sequence);
        Ok(rows)
    }

    /// Get the latest event for a session.
    pub fn get_latest(conn: &Connection, session_id: &str) -> Result<Option<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1"
        );
        let row = conn
            .query_row(&sql, params![session_id], Self::map_row)
            .optional()?;
        Ok(row)
    }

    /// Check if event exists.
    pub fn exists(conn: &Connection, event_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE id = ?1)",
            params![event_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    /// Total event count across all sessions.
    pub fn count(conn: &Connection) -> Result<i64> {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))?;
        Ok(count)
    }

    /// Delete all events for a session. Returns count deleted.
    pub fn delete_by_session(conn: &Connection, session_id: &str) -> Result<usize> {
        let changed = conn.execute(
            "DELETE FROM events WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(changed)
    }
}
