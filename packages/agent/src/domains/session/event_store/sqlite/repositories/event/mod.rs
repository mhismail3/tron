//! Event repository — core event log operations.
//!
//! The event log is the heart of event sourcing. Events are immutable, append-only,
//! and form a tree structure via `parent_id` chains. This repository provides
//! low-level CRUD, tree traversal (ancestors/descendants via recursive CTEs),
//! and query operations.
//!
//! ## Submodules
//!
//! | Module            | Contents                                              |
//! |-------------------|-------------------------------------------------------|
//! | `crud`            | insert, get_by_id, get_latest, exists, count, session-scoped delete |
//! | `extractors`      | Free functions that pull denormalized fields from JSON |
//! | `session_queries` | Session-scoped listing and pagination                 |
//! | `tree_queries`    | Ancestor / child / descendant recursive CTEs          |
//! | `type_queries`    | Type-filtered, workspace-scoped, and global queries   |

use rusqlite::{Connection, OptionalExtension, params};

use crate::domains::session::event_store::EventRow;
use crate::domains::session::event_store::errors::Result;

mod crud;
pub(crate) mod extractors;
mod session_queries;
mod tree_queries;
mod type_queries;

/// The 25 denormalized columns selected from the `events` table.
///
/// Every query that returns `EventRow` uses this constant so column order
/// is defined in exactly one place.
const EVENT_COLUMNS: &str = "\
    id, session_id, parent_id, sequence, depth, type, timestamp, payload, \
    content_blob_id, workspace_id, role, model_primitive_name, invocation_id, turn, \
    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum, \
    model, latency_ms, stop_reason, has_thinking, provider_type, cost";

const SQLITE_BIND_LIMIT: usize = 900;

/// Options for listing events.
#[derive(Default)]
pub struct ListEventsOptions {
    /// Maximum number of events to return.
    pub limit: Option<i64>,
    /// Number of events to skip.
    pub offset: Option<i64>,
}

/// Event repository — stateless, every method takes `&Connection`.
pub struct EventRepo;

impl EventRepo {
    // ─── Private helpers ─────────────────────────────────────────────────────

    fn compute_depth(conn: &Connection, parent_id: Option<&str>) -> Result<i64> {
        match parent_id {
            None => Ok(0),
            Some(pid) => {
                let depth: Option<i64> = conn
                    .query_row(
                        "SELECT depth FROM events WHERE id = ?1",
                        params![pid],
                        |row| row.get(0),
                    )
                    .optional()?;
                Ok(depth.unwrap_or(0) + 1)
            }
        }
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<EventRow> {
        Ok(EventRow {
            id: row.get("id")?,
            session_id: row.get("session_id")?,
            parent_id: row.get("parent_id")?,
            sequence: row.get("sequence")?,
            depth: row.get("depth")?,
            event_type: row.get("type")?,
            timestamp: row.get("timestamp")?,
            payload: row.get("payload")?,
            content_blob_id: row.get("content_blob_id")?,
            workspace_id: row.get("workspace_id")?,
            role: row.get("role")?,
            model_primitive_name: row.get("model_primitive_name")?,
            invocation_id: row.get("invocation_id")?,
            turn: row.get("turn")?,
            input_tokens: row.get("input_tokens")?,
            output_tokens: row.get("output_tokens")?,
            cache_read_tokens: row.get("cache_read_tokens")?,
            cache_creation_tokens: row.get("cache_creation_tokens")?,
            checksum: row.get("checksum")?,
            model: row.get("model")?,
            latency_ms: row.get("latency_ms")?,
            stop_reason: row.get("stop_reason")?,
            has_thinking: row.get("has_thinking")?,
            provider_type: row.get("provider_type")?,
            cost: row.get("cost")?,
        })
    }
}

#[cfg(test)]
#[allow(unused_results)]
mod tests;
