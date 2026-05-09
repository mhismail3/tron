use rusqlite::{Connection, params};

use super::{EVENT_COLUMNS, EventRepo};
use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::sqlite::row_types::EventRow;

impl EventRepo {
    /// Get ancestor chain from root to the given event (inclusive), using recursive CTE.
    pub fn get_ancestors(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let sql = format!(
            "WITH RECURSIVE ancestors({EVENT_COLUMNS}, lvl) AS (
               SELECT {EVENT_COLUMNS}, 0
               FROM events WHERE id = ?1
               UNION ALL
               SELECT e.id, e.session_id, e.parent_id, e.sequence, e.depth, e.type, e.timestamp, e.payload,
                      e.content_blob_id, e.workspace_id, e.role, e.tool_name, e.tool_call_id, e.turn,
                      e.input_tokens, e.output_tokens, e.cache_read_tokens, e.cache_creation_tokens, e.checksum,
                      e.model, e.latency_ms, e.stop_reason, e.has_thinking, e.provider_type, e.cost, a.lvl + 1
               FROM events e JOIN ancestors a ON e.id = a.parent_id
               WHERE a.lvl < 10000
             )
             SELECT {EVENT_COLUMNS}
             FROM ancestors ORDER BY lvl DESC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get direct children of an event.
    pub fn get_children(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let sql = format!(
            "SELECT {EVENT_COLUMNS} FROM events WHERE parent_id = ?1 ORDER BY sequence ASC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get all descendants of an event (recursive CTE downward).
    pub fn get_descendants(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let sql = format!(
            "WITH RECURSIVE desc({EVENT_COLUMNS}, lvl) AS (
               SELECT {EVENT_COLUMNS}, 0
               FROM events WHERE parent_id = ?1
               UNION ALL
               SELECT e.id, e.session_id, e.parent_id, e.sequence, e.depth, e.type, e.timestamp, e.payload,
                      e.content_blob_id, e.workspace_id, e.role, e.tool_name, e.tool_call_id, e.turn,
                      e.input_tokens, e.output_tokens, e.cache_read_tokens, e.cache_creation_tokens, e.checksum,
                      e.model, e.latency_ms, e.stop_reason, e.has_thinking, e.provider_type, e.cost, d.lvl + 1
               FROM events e JOIN desc d ON e.parent_id = d.id
               WHERE d.lvl < 10000
             )
             SELECT {EVENT_COLUMNS}
             FROM desc ORDER BY sequence ASC"
        );
        let mut stmt = conn.prepare_cached(&sql)?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
}
