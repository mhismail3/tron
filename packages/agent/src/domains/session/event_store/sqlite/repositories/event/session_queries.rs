use rusqlite::{Connection, params};

use super::{EVENT_COLUMNS, EventRepo, ListEventsOptions};
use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::errors::Result;

impl EventRepo {
    /// Get events for a session, ordered by sequence.
    pub fn get_by_session(
        conn: &Connection,
        session_id: &str,
        opts: &ListEventsOptions,
    ) -> Result<Vec<EventRow>> {
        let mut sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 ORDER BY sequence ASC"
        );
        if let Some(limit) = opts.limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = opts.offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Count events in a session.
    pub fn count_by_session(conn: &Connection, session_id: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Get events after a specific sequence number.
    pub fn get_since(
        conn: &Connection,
        session_id: &str,
        after_sequence: i64,
    ) -> Result<Vec<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 AND sequence > ?2 ORDER BY sequence ASC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![session_id, after_sequence], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get the most recent N events for a session, returned in sequence ASC order.
    ///
    /// If `limit` is `None`, returns all events. This is used for the initial
    /// `session.reconstruct` call to load the tail of history.
    pub fn get_latest_events(
        conn: &Connection,
        session_id: &str,
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let sql = if let Some(n) = limit {
            // Subquery to get the last N by sequence DESC, then re-order ASC
            format!(
                "SELECT * FROM (SELECT {EVENT_COLUMNS} FROM events \
                 WHERE session_id = ?1 ORDER BY sequence DESC LIMIT {n}) \
                 ORDER BY sequence ASC"
            )
        } else {
            format!(
                "SELECT {EVENT_COLUMNS} FROM events WHERE session_id = ?1 ORDER BY sequence ASC"
            )
        };
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get events with sequence < `before_sequence`, returned in sequence ASC order.
    ///
    /// Used for previous-page pagination in `session.reconstruct` (load-more).
    pub fn get_events_before(
        conn: &Connection,
        session_id: &str,
        before_sequence: i64,
        limit: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        let sql = if let Some(n) = limit {
            format!(
                "SELECT * FROM (SELECT {EVENT_COLUMNS} FROM events \
                 WHERE session_id = ?1 AND sequence < ?2 \
                 ORDER BY sequence DESC LIMIT {n}) \
                 ORDER BY sequence ASC"
            )
        } else {
            format!(
                "SELECT {EVENT_COLUMNS} FROM events \
                 WHERE session_id = ?1 AND sequence < ?2 \
                 ORDER BY sequence ASC"
            )
        };
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![session_id, before_sequence], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Check if events exist with sequence < `before_sequence`.
    ///
    /// Used to determine `hasMoreEvents` in `session.reconstruct` responses.
    pub fn has_events_before(
        conn: &Connection,
        session_id: &str,
        before_sequence: i64,
    ) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE session_id = ?1 AND sequence < ?2)",
            params![session_id, before_sequence],
            |row| row.get(0),
        )?;
        Ok(exists)
    }
}
