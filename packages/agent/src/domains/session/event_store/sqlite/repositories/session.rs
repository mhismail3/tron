//! Session repository — session lifecycle and aggregate counters.
//!
//! Sessions are pointers into the event tree with denormalized counters
//! (event count, token usage, cost) for efficient queries.
//!
//! Dashboard projections live in `session/projections.rs`; this root stays on
//! session lifecycle, listing, counters, and head/root mutation.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::sqlite::row_types::SessionRow;

#[path = "session/projections.rs"]
mod projections;
#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;

#[cfg(test)]
use projections::extract_text_from_payload;
pub use projections::{ActivitySummaryLine, MessagePreview};

/// Options for creating a new session.
pub struct CreateSessionOptions<'a> {
    /// Workspace this session belongs to.
    pub workspace_id: &'a str,
    /// LLM model ID.
    pub model: &'a str,
    /// Working directory path.
    pub working_directory: &'a str,
    /// Optional title.
    pub title: Option<&'a str>,
    /// Optional tags.
    pub tags: Option<&'a [String]>,
    /// Parent session (for forks).
    pub parent_session_id: Option<&'a str>,
    /// Fork point event.
    pub fork_from_event_id: Option<&'a str>,
}

/// Options for listing sessions.
#[derive(Default)]
pub struct ListSessionsOptions<'a> {
    /// Filter by workspace.
    pub workspace_id: Option<&'a str>,
    /// Filter by workspace filesystem path.
    pub working_directory: Option<&'a str>,
    /// Filter by ended state.
    pub ended: Option<bool>,
    /// Maximum results.
    pub limit: Option<i64>,
    /// Skip results.
    pub offset: Option<i64>,
}

/// Counters to increment atomically.
#[derive(Default)]
pub struct IncrementCounters {
    /// Number of events to add.
    pub event_count: Option<i64>,
    /// Number of messages to add.
    pub message_count: Option<i64>,
    /// Number of turns to add.
    pub turn_count: Option<i64>,
    /// Input tokens to add.
    pub input_tokens: Option<i64>,
    /// Output tokens to add.
    pub output_tokens: Option<i64>,
    /// Set (not increment) last turn input tokens.
    pub last_turn_input_tokens: Option<i64>,
    /// Cost to add.
    pub cost: Option<f64>,
    /// Cache read tokens to add.
    pub cache_read_tokens: Option<i64>,
    /// Cache creation tokens to add.
    pub cache_creation_tokens: Option<i64>,
}

/// Session repository — stateless, every method takes `&Connection`.
pub struct SessionRepo;

impl SessionRepo {
    /// Create a new session.
    pub fn create(conn: &Connection, opts: &CreateSessionOptions<'_>) -> Result<SessionRow> {
        let id = format!("sess_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let tags_json = opts.tags.map_or_else(
            || "[]".to_string(),
            |t| serde_json::to_string(t).unwrap_or_else(|_| "[]".to_string()),
        );

        let _ = conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory,
             parent_session_id, fork_from_event_id, created_at, last_activity_at, tags)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                id,
                opts.workspace_id,
                opts.title,
                opts.model,
                opts.working_directory,
                opts.parent_session_id,
                opts.fork_from_event_id,
                now,
                now,
                tags_json,
            ],
        )?;

        Ok(SessionRow {
            id,
            workspace_id: opts.workspace_id.to_string(),
            head_event_id: None,
            root_event_id: None,
            title: opts.title.map(String::from),
            latest_model: opts.model.to_string(),
            working_directory: opts.working_directory.to_string(),
            parent_session_id: opts.parent_session_id.map(String::from),
            fork_from_event_id: opts.fork_from_event_id.map(String::from),
            created_at: now.clone(),
            last_activity_at: now,
            ended_at: None,
            event_count: 0,
            message_count: 0,
            turn_count: 0,
            total_input_tokens: 0,
            total_output_tokens: 0,
            last_turn_input_tokens: 0,
            total_cost: 0.0,
            total_cache_read_tokens: 0,
            total_cache_creation_tokens: 0,
            tags: tags_json,
        })
    }

    /// Get session by ID.
    pub fn get_by_id(conn: &Connection, session_id: &str) -> Result<Option<SessionRow>> {
        let row = conn
            .query_row(
                "SELECT * FROM sessions WHERE id = ?1",
                params![session_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// List sessions with filtering.
    pub fn list(conn: &Connection, opts: &ListSessionsOptions<'_>) -> Result<Vec<SessionRow>> {
        use std::fmt::Write;
        let mut sql = String::from("SELECT * FROM sessions WHERE 1=1");
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ws_id) = opts.workspace_id {
            let _ = write!(sql, " AND workspace_id = ?{}", param_values.len() + 1);
            param_values.push(Box::new(ws_id.to_string()));
        }
        if let Some(working_directory) = opts.working_directory {
            let _ = write!(sql, " AND working_directory = ?{}", param_values.len() + 1);
            param_values.push(Box::new(working_directory.to_string()));
        }
        if let Some(ended) = opts.ended {
            if ended {
                sql.push_str(" AND ended_at IS NOT NULL");
            } else {
                sql.push_str(" AND ended_at IS NULL");
            }
        }
        sql.push_str(" ORDER BY last_activity_at DESC");
        if let Some(limit) = opts.limit {
            let _ = write!(sql, " LIMIT {limit}");
        } else if opts.offset.is_some() {
            sql.push_str(" LIMIT -1");
        }
        if let Some(offset) = opts.offset {
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(Box::as_ref).collect();
        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Update head event ID and last activity.
    pub fn update_head(conn: &Connection, session_id: &str, head_event_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET head_event_id = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![head_event_id, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update root event ID.
    pub fn update_root(conn: &Connection, session_id: &str, root_event_id: &str) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE sessions SET root_event_id = ?1 WHERE id = ?2",
            params![root_event_id, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Mark session as ended.
    pub fn mark_ended(conn: &Connection, session_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET ended_at = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![now, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Clear ended status (reactivate session).
    pub fn clear_ended(conn: &Connection, session_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET ended_at = NULL, last_activity_at = ?1 WHERE id = ?2",
            params![now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update the latest model used.
    pub fn update_latest_model(conn: &Connection, session_id: &str, model: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET latest_model = ?1, last_activity_at = ?2, last_turn_input_tokens = 0 WHERE id = ?3",
            params![model, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update session title.
    pub fn update_title(conn: &Connection, session_id: &str, title: Option<&str>) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE sessions SET title = ?1 WHERE id = ?2",
            params![title, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Increment denormalized counters atomically.
    pub fn increment_counters(
        conn: &Connection,
        session_id: &str,
        counters: &IncrementCounters,
    ) -> Result<bool> {
        let mut updates = Vec::new();

        if let Some(v) = counters.event_count {
            updates.push(format!("event_count = event_count + {v}"));
        }
        if let Some(v) = counters.message_count {
            updates.push(format!("message_count = message_count + {v}"));
        }
        if let Some(v) = counters.turn_count {
            updates.push(format!("turn_count = turn_count + {v}"));
        }
        if let Some(v) = counters.input_tokens {
            updates.push(format!("total_input_tokens = total_input_tokens + {v}"));
        }
        if let Some(v) = counters.output_tokens {
            updates.push(format!("total_output_tokens = total_output_tokens + {v}"));
        }
        if let Some(v) = counters.last_turn_input_tokens {
            updates.push(format!("last_turn_input_tokens = {v}"));
        }
        if let Some(v) = counters.cost {
            updates.push(format!("total_cost = total_cost + {v}"));
        }
        if let Some(v) = counters.cache_read_tokens {
            updates.push(format!(
                "total_cache_read_tokens = total_cache_read_tokens + {v}"
            ));
        }
        if let Some(v) = counters.cache_creation_tokens {
            updates.push(format!(
                "total_cache_creation_tokens = total_cache_creation_tokens + {v}"
            ));
        }

        if updates.is_empty() {
            return Ok(false);
        }

        let now = chrono::Utc::now().to_rfc3339();
        updates.push(format!("last_activity_at = '{now}'"));

        let sql = format!("UPDATE sessions SET {} WHERE id = ?1", updates.join(", "));
        let changed = conn.execute(&sql, params![session_id])?;
        Ok(changed > 0)
    }

    /// Check if session exists.
    pub fn exists(conn: &Connection, session_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?1)",
            params![session_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    /// Delete a session.
    pub fn delete(conn: &Connection, session_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM sessions WHERE id = ?1", params![session_id])?;
        Ok(changed > 0)
    }

    /// Batch-fetch sessions by IDs.
    ///
    /// Returns a map of `session_id → SessionRow`. Missing IDs are silently omitted.
    /// Uses dynamic `IN (?)` placeholders — safe for reasonable batch sizes (<1000).
    pub fn get_by_ids(
        conn: &Connection,
        session_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, SessionRow>> {
        let mut result = std::collections::HashMap::new();
        if session_ids.is_empty() {
            return Ok(result);
        }

        let placeholders: Vec<String> = (1..=session_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT * FROM sessions WHERE id IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = session_ids
            .iter()
            .map(|s| s as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        for row in rows {
            let _ = result.insert(row.id.clone(), row);
        }
        Ok(result)
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRow> {
        Ok(SessionRow {
            id: row.get("id")?,
            workspace_id: row.get("workspace_id")?,
            head_event_id: row.get("head_event_id")?,
            root_event_id: row.get("root_event_id")?,
            title: row.get("title")?,
            latest_model: row.get("latest_model")?,
            working_directory: row.get("working_directory")?,
            parent_session_id: row.get("parent_session_id")?,
            fork_from_event_id: row.get("fork_from_event_id")?,
            created_at: row.get("created_at")?,
            last_activity_at: row.get("last_activity_at")?,
            ended_at: row.get("ended_at")?,
            event_count: row.get("event_count")?,
            message_count: row.get("message_count")?,
            turn_count: row.get("turn_count")?,
            total_input_tokens: row.get("total_input_tokens")?,
            total_output_tokens: row.get("total_output_tokens")?,
            last_turn_input_tokens: row.get("last_turn_input_tokens")?,
            total_cost: row.get("total_cost")?,
            total_cache_read_tokens: row.get("total_cache_read_tokens")?,
            total_cache_creation_tokens: row.get("total_cache_creation_tokens")?,
            tags: row.get("tags")?,
        })
    }
}
