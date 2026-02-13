//! Event repository — core event log operations.
//!
//! The event log is the heart of event sourcing. Events are immutable, append-only,
//! and form a tree structure via `parent_id` chains. This repository provides
//! low-level CRUD, tree traversal (ancestors/descendants via recursive CTEs),
//! and query operations.

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;

use crate::errors::Result;
use crate::sqlite::row_types::EventRow;
use crate::types::SessionEvent;

/// Options for listing events.
#[derive(Default)]
pub struct ListEventsOptions {
    /// Maximum number of events to return.
    pub limit: Option<i64>,
    /// Number of events to skip.
    pub offset: Option<i64>,
}

/// Token usage summary.
#[derive(Debug, Clone, Default)]
pub struct TokenUsageSummary {
    /// Total input tokens.
    pub input_tokens: i64,
    /// Total output tokens.
    pub output_tokens: i64,
    /// Total cache read tokens.
    pub cache_read_tokens: i64,
    /// Total cache creation tokens.
    pub cache_creation_tokens: i64,
}

/// Event repository — stateless, every method takes `&Connection`.
pub struct EventRepo;

impl EventRepo {
    /// Insert a single event, extracting denormalized fields from the payload.
    pub fn insert(conn: &Connection, event: &SessionEvent) -> Result<()> {
        let role = extract_role(event);
        let tool_name = extract_tool_name(event);
        let tool_call_id = extract_str(&event.payload, "toolCallId");
        let turn = extract_i64(&event.payload, "turn");
        let depth = Self::compute_depth(conn, event.parent_id.as_deref())?;

        // Extract token usage from payload.tokenUsage or payload directly
        let (input_tokens, output_tokens, cache_read, cache_create) = extract_tokens(&event.payload);

        let payload_str = serde_json::to_string(&event.payload)?;

        let _ = conn.execute(
            "INSERT INTO events (id, session_id, parent_id, sequence, depth, type, timestamp, payload,
             content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
             input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
            params![
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
                tool_call_id,
                turn,
                input_tokens,
                output_tokens,
                cache_read,
                cache_create,
                event.checksum,
            ],
        )?;
        Ok(())
    }

    /// Get a single event by ID.
    pub fn get_by_id(conn: &Connection, event_id: &str) -> Result<Option<EventRow>> {
        let row = conn
            .query_row(
                "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                        content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
                 FROM events WHERE id = ?1",
                params![event_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Get events for a session, ordered by sequence.
    pub fn get_by_session(
        conn: &Connection,
        session_id: &str,
        opts: &ListEventsOptions,
    ) -> Result<Vec<EventRow>> {
        let mut sql = String::from(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE session_id = ?1 ORDER BY sequence ASC",
        );
        if let Some(limit) = opts.limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = opts.offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get next sequence number for a session.
    pub fn get_next_sequence(conn: &Connection, session_id: &str) -> Result<i64> {
        let max: Option<i64> = conn
            .query_row(
                "SELECT MAX(sequence) FROM events WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        Ok(max.unwrap_or(0) + 1)
    }

    /// Get ancestor chain from root to the given event (inclusive), using recursive CTE.
    pub fn get_ancestors(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let mut stmt = conn.prepare(
            "WITH RECURSIVE ancestors(id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum, lvl) AS (
               SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                      content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                      input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum, 0
               FROM events WHERE id = ?1
               UNION ALL
               SELECT e.id, e.session_id, e.parent_id, e.sequence, e.depth, e.type, e.timestamp, e.payload,
                      e.content_blob_id, e.workspace_id, e.role, e.tool_name, e.tool_call_id, e.turn,
                      e.input_tokens, e.output_tokens, e.cache_read_tokens, e.cache_creation_tokens, e.checksum, a.lvl + 1
               FROM events e JOIN ancestors a ON e.id = a.parent_id
               WHERE a.lvl < 10000
             )
             SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM ancestors ORDER BY lvl DESC",
        )?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get direct children of an event.
    pub fn get_children(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let mut stmt = conn.prepare(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE parent_id = ?1 ORDER BY sequence ASC",
        )?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get all descendants of an event (recursive CTE downward).
    pub fn get_descendants(conn: &Connection, event_id: &str) -> Result<Vec<EventRow>> {
        let mut stmt = conn.prepare(
            "WITH RECURSIVE desc(id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum, lvl) AS (
               SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                      content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                      input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum, 0
               FROM events WHERE parent_id = ?1
               UNION ALL
               SELECT e.id, e.session_id, e.parent_id, e.sequence, e.depth, e.type, e.timestamp, e.payload,
                      e.content_blob_id, e.workspace_id, e.role, e.tool_name, e.tool_call_id, e.turn,
                      e.input_tokens, e.output_tokens, e.cache_read_tokens, e.cache_creation_tokens, e.checksum, d.lvl + 1
               FROM events e JOIN desc d ON e.parent_id = d.id
               WHERE d.lvl < 10000
             )
             SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM desc ORDER BY sequence ASC",
        )?;
        let rows = stmt
            .query_map(params![event_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get events after a specific sequence number.
    pub fn get_since(
        conn: &Connection,
        session_id: &str,
        after_sequence: i64,
    ) -> Result<Vec<EventRow>> {
        let mut stmt = conn.prepare(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE session_id = ?1 AND sequence > ?2 ORDER BY sequence ASC",
        )?;
        let rows = stmt
            .query_map(params![session_id, after_sequence], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get the latest event for a session.
    pub fn get_latest(conn: &Connection, session_id: &str) -> Result<Option<EventRow>> {
        let row = conn
            .query_row(
                "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                        content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
                 FROM events WHERE session_id = ?1 ORDER BY sequence DESC LIMIT 1",
                params![session_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
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

    /// Count events of a specific type in a session.
    pub fn count_by_type(conn: &Connection, session_id: &str, event_type: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = ?1 AND type = ?2",
            params![session_id, event_type],
            |row| row.get(0),
        )?;
        Ok(count)
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

    /// Delete a single event.
    pub fn delete(conn: &Connection, event_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM events WHERE id = ?1", params![event_id])?;
        Ok(changed > 0)
    }

    /// Delete all events for a session. Returns count deleted.
    pub fn delete_by_session(conn: &Connection, session_id: &str) -> Result<usize> {
        let changed = conn.execute(
            "DELETE FROM events WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(changed)
    }

    /// Aggregate token usage across all events in a session.
    pub fn get_token_usage_summary(
        conn: &Connection,
        session_id: &str,
    ) -> Result<TokenUsageSummary> {
        let summary = conn.query_row(
            "SELECT COALESCE(SUM(input_tokens), 0),
                    COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cache_read_tokens), 0),
                    COALESCE(SUM(cache_creation_tokens), 0)
             FROM events WHERE session_id = ?1",
            params![session_id],
            |row| {
                Ok(TokenUsageSummary {
                    input_tokens: row.get(0)?,
                    output_tokens: row.get(1)?,
                    cache_read_tokens: row.get(2)?,
                    cache_creation_tokens: row.get(3)?,
                })
            },
        )?;
        Ok(summary)
    }

    /// Total event count across all sessions.
    pub fn count(conn: &Connection) -> Result<i64> {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM events", [], |row| row.get(0))?;
        Ok(count)
    }

    /// Batch-fetch events by IDs.
    ///
    /// Returns a map of `event_id → EventRow`. Missing IDs are silently omitted.
    pub fn get_by_ids(
        conn: &Connection,
        event_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, EventRow>> {
        let mut result = std::collections::HashMap::new();
        if event_ids.is_empty() {
            return Ok(result);
        }

        let placeholders: Vec<String> = (1..=event_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE id IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = event_ids
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
        let placeholders: Vec<String> =
            (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE session_id = ?1 AND type IN ({}) ORDER BY sequence ASC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        params.push(Box::new(session_id.to_string()));
        for t in types {
            params.push(Box::new(t.to_string()));
        }
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(Box::as_ref).collect();

        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get events by workspace and types (cross-session).
    pub fn get_by_workspace_and_types(
        conn: &Connection,
        workspace_id: &str,
        types: &[&str],
        limit: Option<i64>,
        offset: Option<i64>,
    ) -> Result<Vec<EventRow>> {
        if types.is_empty() {
            return Ok(Vec::new());
        }

        let placeholders: Vec<String> =
            (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let mut sql = format!(
            "SELECT id, session_id, parent_id, sequence, depth, type, timestamp, payload,
                    content_blob_id, workspace_id, role, tool_name, tool_call_id, turn,
                    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens, checksum
             FROM events WHERE workspace_id = ?1 AND type IN ({}) ORDER BY timestamp DESC",
            placeholders.join(", ")
        );
        if let Some(limit) = limit {
            use std::fmt::Write;
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = offset {
            use std::fmt::Write;
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        params.push(Box::new(workspace_id.to_string()));
        for t in types {
            params.push(Box::new(t.to_string()));
        }
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(Box::as_ref).collect();

        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Count events by workspace and types.
    pub fn count_by_workspace_and_types(
        conn: &Connection,
        workspace_id: &str,
        types: &[&str],
    ) -> Result<i64> {
        if types.is_empty() {
            return Ok(0);
        }

        let placeholders: Vec<String> =
            (2..=types.len() + 1).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT COUNT(*) FROM events WHERE workspace_id = ?1 AND type IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        params.push(Box::new(workspace_id.to_string()));
        for t in types {
            params.push(Box::new(t.to_string()));
        }
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(Box::as_ref).collect();

        let count: i64 = stmt.query_row(params_refs.as_slice(), |row| row.get(0))?;
        Ok(count)
    }

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
            id: row.get(0)?,
            session_id: row.get(1)?,
            parent_id: row.get(2)?,
            sequence: row.get(3)?,
            depth: row.get(4)?,
            event_type: row.get(5)?,
            timestamp: row.get(6)?,
            payload: row.get(7)?,
            content_blob_id: row.get(8)?,
            workspace_id: row.get(9)?,
            role: row.get(10)?,
            tool_name: row.get(11)?,
            tool_call_id: row.get(12)?,
            turn: row.get(13)?,
            input_tokens: row.get(14)?,
            output_tokens: row.get(15)?,
            cache_read_tokens: row.get(16)?,
            cache_creation_tokens: row.get(17)?,
            checksum: row.get(18)?,
        })
    }
}

// ─── Extraction helpers ──────────────────────────────────────────────────────

fn extract_role(event: &SessionEvent) -> Option<String> {
    let t = event.event_type.as_str();
    if t.starts_with("message.") {
        match t {
            "message.user" => Some("user".to_string()),
            "message.assistant" => Some("assistant".to_string()),
            "message.system" => Some("system".to_string()),
            _ => None,
        }
    } else if t == "tool.result" {
        Some("tool".to_string())
    } else {
        None
    }
}

fn extract_tool_name(event: &SessionEvent) -> Option<String> {
    extract_str(&event.payload, "toolName")
        .or_else(|| extract_str(&event.payload, "name"))
}

fn extract_str(val: &Value, key: &str) -> Option<String> {
    val.get(key)?.as_str().map(String::from)
}

fn extract_i64(val: &Value, key: &str) -> Option<i64> {
    val.get(key)?.as_i64()
}

fn extract_tokens(payload: &Value) -> (Option<i64>, Option<i64>, Option<i64>, Option<i64>) {
    // Try payload.tokenUsage first (assistant messages)
    if let Some(tu) = payload.get("tokenUsage") {
        return (
            tu.get("inputTokens").and_then(Value::as_i64),
            tu.get("outputTokens").and_then(Value::as_i64),
            tu.get("cacheReadInputTokens").and_then(Value::as_i64),
            tu.get("cacheCreationInputTokens").and_then(Value::as_i64),
        );
    }
    // Try top-level (some event types put tokens directly)
    (
        extract_i64(payload, "inputTokens"),
        extract_i64(payload, "outputTokens"),
        extract_i64(payload, "cacheReadInputTokens"),
        extract_i64(payload, "cacheCreationInputTokens"),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::sqlite::migrations::run_migrations;
    use crate::types::EventType;
    use serde_json::json;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();

        // Create workspace and session
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', datetime('now'), datetime('now'))",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
            [],
        )
        .unwrap();
        conn
    }

    fn make_event(id: &str, seq: i64, event_type: EventType, parent_id: Option<&str>, payload: Value) -> SessionEvent {
        SessionEvent {
            id: id.to_string(),
            parent_id: parent_id.map(String::from),
            session_id: "sess_1".to_string(),
            workspace_id: "ws_1".to_string(),
            timestamp: "2025-01-01T00:00:00Z".to_string(),
            event_type,
            sequence: seq,
            checksum: None,
            payload,
        }
    }

    #[test]
    fn insert_and_get() {
        let conn = setup();
        let event = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        EventRepo::insert(&conn, &event).unwrap();

        let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
        assert_eq!(row.id, "evt_1");
        assert_eq!(row.session_id, "sess_1");
        assert_eq!(row.sequence, 1);
        assert_eq!(row.depth, 0);
        assert_eq!(row.event_type, "session.start");
    }

    #[test]
    fn insert_extracts_role() {
        let conn = setup();
        let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({"content": "hi"}));
        EventRepo::insert(&conn, &event).unwrap();

        let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
        assert_eq!(row.role.as_deref(), Some("user"));
    }

    #[test]
    fn insert_extracts_tool_name() {
        let conn = setup();
        let event = make_event("evt_1", 1, EventType::ToolCall, None, json!({"toolName": "bash", "toolCallId": "tc_1"}));
        EventRepo::insert(&conn, &event).unwrap();

        let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
        assert_eq!(row.tool_name.as_deref(), Some("bash"));
        assert_eq!(row.tool_call_id.as_deref(), Some("tc_1"));
    }

    #[test]
    fn insert_extracts_tokens() {
        let conn = setup();
        let event = make_event("evt_1", 1, EventType::MessageAssistant, None, json!({
            "content": "hello",
            "tokenUsage": {
                "inputTokens": 100,
                "outputTokens": 50,
                "cacheReadInputTokens": 25
            }
        }));
        EventRepo::insert(&conn, &event).unwrap();

        let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
        assert_eq!(row.input_tokens, Some(100));
        assert_eq!(row.output_tokens, Some(50));
        assert_eq!(row.cache_read_tokens, Some(25));
    }

    #[test]
    fn insert_computes_depth() {
        let conn = setup();
        let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
        let e3 = make_event("evt_3", 3, EventType::MessageAssistant, Some("evt_2"), json!({}));

        EventRepo::insert(&conn, &e1).unwrap();
        EventRepo::insert(&conn, &e2).unwrap();
        EventRepo::insert(&conn, &e3).unwrap();

        assert_eq!(EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap().depth, 0);
        assert_eq!(EventRepo::get_by_id(&conn, "evt_2").unwrap().unwrap().depth, 1);
        assert_eq!(EventRepo::get_by_id(&conn, "evt_3").unwrap().unwrap().depth, 2);
    }

    #[test]
    fn get_by_session() {
        let conn = setup();
        for i in 1..=5 {
            let parent = format!("evt_{}", i - 1);
            let event = make_event(
                &format!("evt_{i}"),
                i,
                EventType::MessageUser,
                if i == 1 { None } else { Some(parent.as_str()) },
                json!({}),
            );
            EventRepo::insert(&conn, &event).unwrap();
        }

        let events = EventRepo::get_by_session(&conn, "sess_1", &ListEventsOptions::default()).unwrap();
        assert_eq!(events.len(), 5);
        assert_eq!(events[0].sequence, 1);
        assert_eq!(events[4].sequence, 5);
    }

    #[test]
    fn get_by_session_with_limit() {
        let conn = setup();
        for i in 1..=5 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }

        let events = EventRepo::get_by_session(&conn, "sess_1", &ListEventsOptions { limit: Some(3), offset: None }).unwrap();
        assert_eq!(events.len(), 3);
    }

    #[test]
    fn get_next_sequence_empty() {
        let conn = setup();
        assert_eq!(EventRepo::get_next_sequence(&conn, "sess_1").unwrap(), 1);
    }

    #[test]
    fn get_next_sequence_after_events() {
        let conn = setup();
        for i in 1..=3 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }
        assert_eq!(EventRepo::get_next_sequence(&conn, "sess_1").unwrap(), 4);
    }

    #[test]
    fn get_ancestors_chain() {
        let conn = setup();
        let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
        let e3 = make_event("evt_3", 3, EventType::MessageAssistant, Some("evt_2"), json!({}));
        let e4 = make_event("evt_4", 4, EventType::ToolCall, Some("evt_3"), json!({}));
        let e5 = make_event("evt_5", 5, EventType::ToolResult, Some("evt_4"), json!({}));

        EventRepo::insert(&conn, &e1).unwrap();
        EventRepo::insert(&conn, &e2).unwrap();
        EventRepo::insert(&conn, &e3).unwrap();
        EventRepo::insert(&conn, &e4).unwrap();
        EventRepo::insert(&conn, &e5).unwrap();

        let ancestors = EventRepo::get_ancestors(&conn, "evt_5").unwrap();
        assert_eq!(ancestors.len(), 5);
        assert_eq!(ancestors[0].id, "evt_1");
        assert_eq!(ancestors[4].id, "evt_5");
    }

    #[test]
    fn get_ancestors_root_only() {
        let conn = setup();
        let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        EventRepo::insert(&conn, &e1).unwrap();

        let ancestors = EventRepo::get_ancestors(&conn, "evt_1").unwrap();
        assert_eq!(ancestors.len(), 1);
        assert_eq!(ancestors[0].id, "evt_1");
    }

    #[test]
    fn get_children() {
        let conn = setup();
        let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
        let e3 = make_event("evt_3", 3, EventType::MessageAssistant, Some("evt_1"), json!({}));

        EventRepo::insert(&conn, &e1).unwrap();
        EventRepo::insert(&conn, &e2).unwrap();
        EventRepo::insert(&conn, &e3).unwrap();

        let children = EventRepo::get_children(&conn, "evt_1").unwrap();
        assert_eq!(children.len(), 2);
    }

    #[test]
    fn get_descendants() {
        let conn = setup();
        let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
        let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
        let e3 = make_event("evt_3", 3, EventType::MessageAssistant, Some("evt_2"), json!({}));

        EventRepo::insert(&conn, &e1).unwrap();
        EventRepo::insert(&conn, &e2).unwrap();
        EventRepo::insert(&conn, &e3).unwrap();

        let desc = EventRepo::get_descendants(&conn, "evt_1").unwrap();
        assert_eq!(desc.len(), 2); // evt_2 and evt_3, not evt_1 itself
    }

    #[test]
    fn get_since() {
        let conn = setup();
        for i in 1..=5 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }

        let events = EventRepo::get_since(&conn, "sess_1", 3).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].sequence, 4);
        assert_eq!(events[1].sequence, 5);
    }

    #[test]
    fn get_latest() {
        let conn = setup();
        for i in 1..=3 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }

        let latest = EventRepo::get_latest(&conn, "sess_1").unwrap().unwrap();
        assert_eq!(latest.sequence, 3);
    }

    #[test]
    fn get_latest_empty() {
        let conn = setup();
        let latest = EventRepo::get_latest(&conn, "sess_1").unwrap();
        assert!(latest.is_none());
    }

    #[test]
    fn count_by_session() {
        let conn = setup();
        assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 0);

        for i in 1..=3 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }
        assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 3);
    }

    #[test]
    fn count_by_type() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_3", 3, EventType::MessageUser, None, json!({}))).unwrap();

        assert_eq!(EventRepo::count_by_type(&conn, "sess_1", "message.user").unwrap(), 2);
        assert_eq!(EventRepo::count_by_type(&conn, "sess_1", "message.assistant").unwrap(), 1);
    }

    #[test]
    fn exists_event() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::SessionStart, None, json!({}))).unwrap();

        assert!(EventRepo::exists(&conn, "evt_1").unwrap());
        assert!(!EventRepo::exists(&conn, "evt_nonexistent").unwrap());
    }

    #[test]
    fn delete_event() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::SessionStart, None, json!({}))).unwrap();

        assert!(EventRepo::delete(&conn, "evt_1").unwrap());
        assert!(!EventRepo::exists(&conn, "evt_1").unwrap());
    }

    #[test]
    fn delete_by_session() {
        let conn = setup();
        for i in 1..=3 {
            let event = make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}));
            EventRepo::insert(&conn, &event).unwrap();
        }

        let deleted = EventRepo::delete_by_session(&conn, "sess_1").unwrap();
        assert_eq!(deleted, 3);
        assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 0);
    }

    #[test]
    fn token_usage_summary() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageAssistant, None, json!({
            "tokenUsage": {"inputTokens": 100, "outputTokens": 50, "cacheReadInputTokens": 20}
        }))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({
            "tokenUsage": {"inputTokens": 200, "outputTokens": 100}
        }))).unwrap();

        let summary = EventRepo::get_token_usage_summary(&conn, "sess_1").unwrap();
        assert_eq!(summary.input_tokens, 300);
        assert_eq!(summary.output_tokens, 150);
        assert_eq!(summary.cache_read_tokens, 20);
    }

    #[test]
    fn token_usage_summary_empty() {
        let conn = setup();
        let summary = EventRepo::get_token_usage_summary(&conn, "sess_1").unwrap();
        assert_eq!(summary.input_tokens, 0);
        assert_eq!(summary.output_tokens, 0);
    }

    #[test]
    fn fts_trigger_indexes_on_insert() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({"content": "search for this phrase"}))).unwrap();

        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events_fts WHERE events_fts MATCH 'phrase'",
            [],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(count, 1);
    }

    // ── Batch operations ─────────────────────────────────────────────

    #[test]
    fn get_by_ids_basic() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({}))).unwrap();

        let ids = ["evt_1", "evt_2"];
        let map = EventRepo::get_by_ids(&conn, &ids).unwrap();
        assert_eq!(map.len(), 2);
        assert!(map.contains_key("evt_1"));
        assert!(map.contains_key("evt_2"));
    }

    #[test]
    fn get_by_ids_empty() {
        let conn = setup();
        let map = EventRepo::get_by_ids(&conn, &[]).unwrap();
        assert!(map.is_empty());
    }

    #[test]
    fn get_by_ids_missing_omitted() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();

        let ids = ["evt_1", "evt_nonexistent"];
        let map = EventRepo::get_by_ids(&conn, &ids).unwrap();
        assert_eq!(map.len(), 1);
    }

    // ── Type-filtered queries ────────────────────────────────────────

    #[test]
    fn get_by_types_basic() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_3", 3, EventType::ToolCall, None, json!({}))).unwrap();

        let types = ["message.user", "message.assistant"];
        let results = EventRepo::get_by_types(&conn, "sess_1", &types, None).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn get_by_types_empty_types() {
        let conn = setup();
        let results = EventRepo::get_by_types(&conn, "sess_1", &[], None).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn get_by_types_with_limit() {
        let conn = setup();
        for i in 1..=5 {
            EventRepo::insert(&conn, &make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}))).unwrap();
        }

        let types = ["message.user"];
        let results = EventRepo::get_by_types(&conn, "sess_1", &types, Some(3)).unwrap();
        assert_eq!(results.len(), 3);
    }

    // ── Workspace-scoped queries ─────────────────────────────────────

    #[test]
    fn get_by_workspace_and_types_basic() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::ToolCall, None, json!({}))).unwrap();

        let types = ["message.user"];
        let results = EventRepo::get_by_workspace_and_types(&conn, "ws_1", &types, None, None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].id, "evt_1");
    }

    #[test]
    fn get_by_workspace_and_types_empty_types() {
        let conn = setup();
        let results = EventRepo::get_by_workspace_and_types(&conn, "ws_1", &[], None, None).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn get_by_workspace_and_types_with_limit_offset() {
        let conn = setup();
        for i in 1..=5 {
            EventRepo::insert(&conn, &make_event(&format!("evt_{i}"), i, EventType::MessageUser, None, json!({}))).unwrap();
        }

        let types = ["message.user"];
        let results = EventRepo::get_by_workspace_and_types(&conn, "ws_1", &types, Some(2), Some(1)).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn count_by_workspace_and_types_basic() {
        let conn = setup();
        EventRepo::insert(&conn, &make_event("evt_1", 1, EventType::MessageUser, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({}))).unwrap();
        EventRepo::insert(&conn, &make_event("evt_3", 3, EventType::ToolCall, None, json!({}))).unwrap();

        let types = ["message.user", "message.assistant"];
        let count = EventRepo::count_by_workspace_and_types(&conn, "ws_1", &types).unwrap();
        assert_eq!(count, 2);
    }

    #[test]
    fn count_by_workspace_and_types_empty_types() {
        let conn = setup();
        let count = EventRepo::count_by_workspace_and_types(&conn, "ws_1", &[]).unwrap();
        assert_eq!(count, 0);
    }
}
