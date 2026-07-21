use rusqlite::{Connection, OptionalExtension, params};

use super::{EVENT_COLUMNS, EventRepo};
use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::types::payloads::TokenTotals;

impl EventRepo {
    /// Get events of specific types within a session.
    pub fn get_by_types(
        conn: &Connection,
        session_id: &str,
        types: &[&str],
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }

        // Build the type placeholders starting after session_id (?1)
        let placeholders: Vec<String> = (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 AND type IN ({}) ORDER BY sequence ASC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let mut param_values = Vec::with_capacity(1 + types.len());
        param_values.push(session_id.to_string());
        param_values.extend(types.iter().map(std::string::ToString::to_string));

        let rows = stmt
            .query_map(
                rusqlite::params_from_iter(param_values.iter()),
                Self::map_row,
            )?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get the latest event of a specific type within a session.
    pub fn get_latest_by_type(
        conn: &Connection,
        session_id: &str,
        event_type: &str,
    ) -> Result<Option<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 AND type = ?2 ORDER BY sequence DESC LIMIT 1"
        );
        Ok(conn
            .query_row(&sql, params![session_id, event_type], Self::map_row)
            .optional()?)
    }

    /// Get the latest event of a specific type and session-turn ordinal.
    pub fn get_latest_by_type_and_turn(
        conn: &Connection,
        session_id: &str,
        event_type: &str,
        turn: i64,
    ) -> Result<Option<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events \
             WHERE session_id = ?1 AND type = ?2 AND turn = ?3 \
             ORDER BY sequence DESC LIMIT 1"
        );
        Ok(conn
            .query_row(&sql, params![session_id, event_type, turn], Self::map_row)
            .optional()?)
    }

    /// Get the greatest denormalized turn ordinal for an event type.
    pub fn get_max_turn_by_type(
        conn: &Connection,
        session_id: &str,
        event_type: &str,
    ) -> Result<Option<i64>> {
        Ok(conn.query_row(
            "SELECT MAX(turn) FROM events WHERE session_id = ?1 AND type = ?2",
            params![session_id, event_type],
            |row| row.get(0),
        )?)
    }

    /// Get each latest durable turn start that has no later terminal row for
    /// the same session and ordinal. Startup recovery owns this cross-session
    /// query because a crash can happen before a streaming journal exists.
    pub fn get_unterminalized_turn_starts(conn: &Connection) -> Result<Vec<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events AS started
             WHERE started.type = 'stream.turn_start'
               AND started.turn IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1 FROM events AS newer
                   WHERE newer.session_id = started.session_id
                     AND newer.turn = started.turn
                     AND newer.type = 'stream.turn_start'
                     AND newer.sequence > started.sequence
               )
               AND NOT EXISTS (
                   SELECT 1 FROM events AS terminal
                   WHERE terminal.session_id = started.session_id
                     AND terminal.turn = started.turn
                     AND terminal.type IN ('stream.turn_end', 'turn.failed')
                     AND terminal.sequence > started.sequence
               )
             ORDER BY started.session_id ASC, started.sequence ASC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map([], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Count events of a specific type in a session.
    pub fn count_by_type(conn: &Connection, session_id: &str, event_type: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = ?1 AND type = ?2",
            params![session_id, event_type],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Aggregate token usage across all events in a session.
    pub fn get_token_usage_summary(conn: &Connection, session_id: &str) -> Result<TokenTotals> {
        let summary = conn.query_row(
            "SELECT COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cache_read_tokens), 0),
                    COALESCE(SUM(cache_creation_tokens), 0)
             FROM events WHERE session_id = ?1",
            params![session_id],
            |row| {
                Ok(TokenTotals {
                    input_tokens: row.get(0)?,
                    output_tokens: row.get(1)?,
                    cache_read_tokens: row.get(2)?,
                    cache_creation_tokens: row.get(3)?,
                })
            },
        )?;
        Ok(summary)
    }
}
