//! Search repository — FTS5 full-text search over events.
//!
//! The `events_fts` table is auto-populated by triggers on INSERT/DELETE of events.
//! This repository provides search, filtering, and index maintenance operations.

use rusqlite::{Connection, OptionalExtension, params};

use crate::errors::Result;
use crate::types::EventType;
use crate::types::state::SearchResult;

/// Options for search queries.
#[derive(Default)]
pub struct SearchOptions<'a> {
    /// Filter by workspace.
    pub workspace_id: Option<&'a str>,
    /// Filter by session.
    pub session_id: Option<&'a str>,
    /// Filter by event types.
    pub types: Option<&'a [EventType]>,
    /// Maximum results.
    pub limit: Option<i64>,
    /// Skip results.
    pub offset: Option<i64>,
}

/// Search repository — stateless, every method takes `&Connection`.
pub struct SearchRepo;

impl SearchRepo {
    /// Full-text search with BM25 ranking and optional filters.
    ///
    /// The `query` parameter uses FTS5 syntax (e.g., `"hello world"`, `hello OR world`,
    /// `hello NOT world`). Results are ranked by relevance.
    pub fn search(
        conn: &Connection,
        query: &str,
        opts: &SearchOptions<'_>,
    ) -> Result<Vec<SearchResult>> {
        use std::fmt::Write;
        let mut sql = String::from(
            "SELECT
               events_fts.id,
               events_fts.session_id,
               events_fts.type,
               snippet(events_fts, 3, '<mark>', '</mark>', '...', 64) as snippet,
               bm25(events_fts) as score,
               e.timestamp
             FROM events_fts
             JOIN events e ON events_fts.id = e.id
             WHERE events_fts MATCH ?1",
        );
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(query.to_string()));

        if let Some(ws_id) = opts.workspace_id {
            let _ = write!(sql, " AND e.workspace_id = ?{}", param_values.len() + 1);
            param_values.push(Box::new(ws_id.to_string()));
        }
        if let Some(sess_id) = opts.session_id {
            let _ = write!(
                sql,
                " AND events_fts.session_id = ?{}",
                param_values.len() + 1
            );
            param_values.push(Box::new(sess_id.to_string()));
        }
        if let Some(types) = opts.types {
            if !types.is_empty() {
                let placeholders: Vec<String> = types
                    .iter()
                    .enumerate()
                    .map(|(i, _)| format!("?{}", param_values.len() + i + 1))
                    .collect();
                let _ = write!(sql, " AND events_fts.type IN ({})", placeholders.join(", "));
                for t in types {
                    param_values.push(Box::new(t.to_string()));
                }
            }
        }

        sql.push_str(" ORDER BY score");

        if let Some(limit) = opts.limit {
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = opts.offset {
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(Box::as_ref).collect();
        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_search_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Search within a specific session.
    pub fn search_in_session(
        conn: &Connection,
        session_id: &str,
        query: &str,
        limit: Option<i64>,
    ) -> Result<Vec<SearchResult>> {
        Self::search(
            conn,
            query,
            &SearchOptions {
                session_id: Some(session_id),
                limit,
                ..Default::default()
            },
        )
    }

    /// Search within a specific workspace.
    pub fn search_in_workspace(
        conn: &Connection,
        workspace_id: &str,
        query: &str,
        limit: Option<i64>,
    ) -> Result<Vec<SearchResult>> {
        Self::search(
            conn,
            query,
            &SearchOptions {
                workspace_id: Some(workspace_id),
                limit,
                ..Default::default()
            },
        )
    }

    /// Search events by tool name using FTS5.
    pub fn search_by_tool_name(
        conn: &Connection,
        tool_name: &str,
        opts: &SearchOptions<'_>,
    ) -> Result<Vec<SearchResult>> {
        use std::fmt::Write;
        let mut sql = String::from(
            "SELECT
               events_fts.id,
               events_fts.session_id,
               events_fts.type,
               snippet(events_fts, 4, '<mark>', '</mark>', '...', 64) as snippet,
               bm25(events_fts) as score,
               e.timestamp
             FROM events_fts
             JOIN events e ON events_fts.id = e.id
             WHERE events_fts.tool_name MATCH ?1",
        );
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
        param_values.push(Box::new(tool_name.to_string()));

        if let Some(ws_id) = opts.workspace_id {
            let _ = write!(sql, " AND e.workspace_id = ?{}", param_values.len() + 1);
            param_values.push(Box::new(ws_id.to_string()));
        }
        if let Some(sess_id) = opts.session_id {
            let _ = write!(
                sql,
                " AND events_fts.session_id = ?{}",
                param_values.len() + 1
            );
            param_values.push(Box::new(sess_id.to_string()));
        }

        sql.push_str(" ORDER BY score");

        if let Some(limit) = opts.limit {
            let _ = write!(sql, " LIMIT {limit}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(Box::as_ref).collect();
        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_search_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Remove an event from the search index.
    pub fn remove(conn: &Connection, event_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM events_fts WHERE id = ?1", params![event_id])?;
        Ok(changed > 0)
    }

    /// Remove all events for a session from the search index.
    pub fn remove_by_session(conn: &Connection, session_id: &str) -> Result<usize> {
        let changed = conn.execute(
            "DELETE FROM events_fts WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(changed)
    }

    /// Check if an event is indexed.
    pub fn is_indexed(conn: &Connection, event_id: &str) -> Result<bool> {
        let found: Option<String> = conn
            .query_row(
                "SELECT id FROM events_fts WHERE id = ?1",
                params![event_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    /// Count indexed events for a session.
    pub fn count_by_session(conn: &Connection, session_id: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM events_fts WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Rebuild the FTS index for a session from the events table.
    ///
    /// Deletes all existing FTS entries for the session, then re-indexes
    /// each event using the same content extraction logic as the triggers.
    /// Returns the number of events re-indexed.
    pub fn rebuild_session_index(conn: &Connection, session_id: &str) -> Result<usize> {
        // Remove existing entries
        let _ = conn.execute(
            "DELETE FROM events_fts WHERE session_id = ?1",
            params![session_id],
        )?;

        // Fetch all events for the session
        let mut stmt = conn.prepare(
            "SELECT id, session_id, type, payload, tool_name
             FROM events WHERE session_id = ?1 ORDER BY sequence ASC",
        )?;
        let events: Vec<(String, String, String, String, Option<String>)> = stmt
            .query_map(params![session_id], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        let count = events.len();
        for (id, sess_id, event_type, payload_str, tool_name) in &events {
            let content = extract_content(payload_str);
            let tool = tool_name
                .clone()
                .unwrap_or_else(|| extract_tool_name(payload_str));
            let _ = conn.execute(
                "INSERT INTO events_fts (id, session_id, type, content, tool_name)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![id, sess_id, event_type, content, tool],
            )?;
        }

        Ok(count)
    }

    fn map_search_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SearchResult> {
        let event_type_str: String = row.get(2)?;
        let event_type = event_type_str
            .parse::<EventType>()
            .unwrap_or(EventType::SessionStart);
        Ok(SearchResult {
            event_id: row.get(0)?,
            session_id: row.get(1)?,
            event_type,
            snippet: row.get(3)?,
            score: row.get(4)?,
            timestamp: row.get(5)?,
        })
    }
}

/// Extract searchable content from an event payload JSON string.
fn extract_content(payload_str: &str) -> String {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(payload_str) else {
        return String::new();
    };

    // For memory.ledger events, concatenate structured fields
    if payload.get("entryType").is_some() || payload.get("actions").is_some() {
        return extract_ledger_content(&payload);
    }

    // Standard: extract from payload.content
    match payload.get("content") {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    b.get("text").and_then(|t| t.as_str()).map(String::from)
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}

/// Extract searchable content from memory.ledger payload.
fn extract_ledger_content(payload: &serde_json::Value) -> String {
    let mut parts = Vec::new();

    if let Some(s) = payload.get("title").and_then(|v| v.as_str()) {
        parts.push(s.to_string());
    }
    if let Some(s) = payload.get("entryType").and_then(|v| v.as_str()) {
        parts.push(s.to_string());
    }
    if let Some(s) = payload.get("status").and_then(|v| v.as_str()) {
        parts.push(s.to_string());
    }
    if let Some(s) = payload.get("input").and_then(|v| v.as_str()) {
        parts.push(s.to_string());
    }
    if let Some(arr) = payload.get("actions").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.as_str() {
                parts.push(s.to_string());
            }
        }
    }
    if let Some(arr) = payload.get("lessons").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.as_str() {
                parts.push(s.to_string());
            }
        }
    }
    if let Some(arr) = payload.get("decisions").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.get("choice").and_then(|v| v.as_str()) {
                parts.push(s.to_string());
            }
            if let Some(s) = item.get("reason").and_then(|v| v.as_str()) {
                parts.push(s.to_string());
            }
        }
    }
    if let Some(arr) = payload.get("files").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.get("path").and_then(|v| v.as_str()) {
                parts.push(s.to_string());
            }
            if let Some(s) = item.get("why").and_then(|v| v.as_str()) {
                parts.push(s.to_string());
            }
        }
    }
    if let Some(arr) = payload.get("tags").and_then(|v| v.as_array()) {
        for item in arr {
            if let Some(s) = item.as_str() {
                parts.push(s.to_string());
            }
        }
    }

    parts.join(" ")
}

/// Extract tool name from payload JSON string.
fn extract_tool_name(payload_str: &str) -> String {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(payload_str) else {
        return String::new();
    };
    payload
        .get("toolName")
        .or_else(|| payload.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::sqlite::migrations::run_migrations;
    use crate::sqlite::repositories::workspace::{CreateWorkspaceOptions, WorkspaceRepo};
    use serde_json::json;

    fn setup() -> (Connection, String) {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();

        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/test",
                name: None,
            },
        )
        .unwrap();

        // Create a session
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', ?1, 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
            params![ws.id],
        )
        .unwrap();

        (conn, ws.id)
    }

    fn insert_event(
        conn: &Connection,
        id: &str,
        session_id: &str,
        workspace_id: &str,
        seq: i64,
        event_type: &str,
        payload: serde_json::Value,
        tool_name: Option<&str>,
    ) {
        let payload_str = serde_json::to_string(&payload).unwrap();
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, tool_name)
             VALUES (?1, ?2, ?3, ?4, datetime('now'), ?5, ?6, ?7)",
            params![id, session_id, seq, event_type, payload_str, workspace_id, tool_name],
        )
        .unwrap();
    }

    #[test]
    fn auto_index_on_insert() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello world"}),
            None,
        );

        assert!(SearchRepo::is_indexed(&conn, "evt_1").unwrap());
    }

    #[test]
    fn auto_index_on_delete() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello world"}),
            None,
        );
        assert!(SearchRepo::is_indexed(&conn, "evt_1").unwrap());

        conn.execute("DELETE FROM events WHERE id = 'evt_1'", [])
            .unwrap();
        assert!(!SearchRepo::is_indexed(&conn, "evt_1").unwrap());
    }

    #[test]
    fn search_basic() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "rust programming language"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.assistant",
            json!({"content": "python scripting language"}),
            None,
        );

        let results = SearchRepo::search(&conn, "rust", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "evt_1");
    }

    #[test]
    fn search_returns_multiple_results() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "programming in rust"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.assistant",
            json!({"content": "programming in python"}),
            None,
        );

        let results = SearchRepo::search(&conn, "programming", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_no_results() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello world"}),
            None,
        );

        let results = SearchRepo::search(&conn, "nonexistent", &SearchOptions::default()).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn search_with_limit() {
        let (conn, ws_id) = setup();
        for i in 1..=5 {
            insert_event(
                &conn,
                &format!("evt_{i}"),
                "sess_1",
                &ws_id,
                i,
                "message.user",
                json!({"content": format!("test message number {i}")}),
                None,
            );
        }

        let results = SearchRepo::search(
            &conn,
            "test",
            &SearchOptions {
                limit: Some(2),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn search_in_session() {
        let (conn, ws_id) = setup();
        // Create a second session
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_2', ?1, 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
            params![ws_id],
        )
        .unwrap();

        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello from session one"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_2",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello from session two"}),
            None,
        );

        let results = SearchRepo::search_in_session(&conn, "sess_1", "hello", None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "sess_1");
    }

    #[test]
    fn search_in_workspace() {
        let (conn, ws_id) = setup();
        // Create second workspace and session
        let ws2 = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/other",
                name: None,
            },
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_2', ?1, 'claude-3', '/tmp/other', datetime('now'), datetime('now'))",
            params![ws2.id],
        )
        .unwrap();

        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello from workspace one"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_2",
            &ws2.id,
            1,
            "message.user",
            json!({"content": "hello from workspace two"}),
            None,
        );

        let results = SearchRepo::search_in_workspace(&conn, &ws_id, "hello", None).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].session_id, "sess_1");
    }

    #[test]
    fn search_by_tool_name() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "tool.call",
            json!({"toolName": "Bash", "input": {"command": "ls"}}),
            Some("Bash"),
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "tool.call",
            json!({"toolName": "Read", "input": {"path": "/tmp/file"}}),
            Some("Read"),
        );

        let results =
            SearchRepo::search_by_tool_name(&conn, "Bash", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_id, "evt_1");
    }

    #[test]
    fn search_with_type_filter() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "test message"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.assistant",
            json!({"content": "test response"}),
            None,
        );

        let results = SearchRepo::search(
            &conn,
            "test",
            &SearchOptions {
                types: Some(&[EventType::MessageUser]),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].event_type, EventType::MessageUser);
    }

    #[test]
    fn search_result_has_snippet() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "the quick brown fox jumps over the lazy dog"}),
            None,
        );

        let results = SearchRepo::search(&conn, "fox", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
        assert!(!results[0].snippet.is_empty());
    }

    #[test]
    fn search_result_has_score() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "rust rust rust"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.user",
            json!({"content": "rust once"}),
            None,
        );

        let results = SearchRepo::search(&conn, "rust", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 2);
        // BM25 returns negative scores (lower = better match)
        // Event with more occurrences should score better (lower BM25 value)
        assert!(results[0].score <= results[1].score);
    }

    #[test]
    fn remove_from_index() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello world"}),
            None,
        );

        assert!(SearchRepo::is_indexed(&conn, "evt_1").unwrap());
        assert!(SearchRepo::remove(&conn, "evt_1").unwrap());
        assert!(!SearchRepo::is_indexed(&conn, "evt_1").unwrap());
    }

    #[test]
    fn remove_nonexistent() {
        let (conn, _) = setup();
        assert!(!SearchRepo::remove(&conn, "evt_nonexistent").unwrap());
    }

    #[test]
    fn remove_by_session() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.user",
            json!({"content": "world"}),
            None,
        );

        let removed = SearchRepo::remove_by_session(&conn, "sess_1").unwrap();
        assert_eq!(removed, 2);
        assert_eq!(SearchRepo::count_by_session(&conn, "sess_1").unwrap(), 0);
    }

    #[test]
    fn count_by_session() {
        let (conn, ws_id) = setup();
        assert_eq!(SearchRepo::count_by_session(&conn, "sess_1").unwrap(), 0);

        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.user",
            json!({"content": "world"}),
            None,
        );

        assert_eq!(SearchRepo::count_by_session(&conn, "sess_1").unwrap(), 2);
    }

    #[test]
    fn rebuild_session_index() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.user",
            json!({"content": "hello world"}),
            None,
        );
        insert_event(
            &conn,
            "evt_2",
            "sess_1",
            &ws_id,
            2,
            "message.user",
            json!({"content": "foo bar"}),
            None,
        );

        // Manually clear the FTS index
        conn.execute("DELETE FROM events_fts WHERE session_id = 'sess_1'", [])
            .unwrap();
        assert_eq!(SearchRepo::count_by_session(&conn, "sess_1").unwrap(), 0);

        // Rebuild
        let count = SearchRepo::rebuild_session_index(&conn, "sess_1").unwrap();
        assert_eq!(count, 2);
        assert_eq!(SearchRepo::count_by_session(&conn, "sess_1").unwrap(), 2);

        // Search should work again
        let results = SearchRepo::search(&conn, "hello", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn search_content_blocks_array() {
        let (conn, ws_id) = setup();
        insert_event(
            &conn,
            "evt_1",
            "sess_1",
            &ws_id,
            1,
            "message.assistant",
            json!({
                "content": [
                    {"type": "text", "text": "hello from the assistant"},
                    {"type": "tool_use", "id": "tool_1", "name": "Bash"}
                ]
            }),
            None,
        );

        // FTS trigger extracts from payload.content which is an array
        // The trigger uses json_extract(payload, '$.content') which returns the JSON array as string
        // Manual rebuild will do the smart extraction
        SearchRepo::rebuild_session_index(&conn, "sess_1").unwrap();

        let results = SearchRepo::search(&conn, "assistant", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn extract_content_string() {
        let content = extract_content(r#"{"content": "hello world"}"#);
        assert_eq!(content, "hello world");
    }

    #[test]
    fn extract_content_blocks() {
        let content = extract_content(
            r#"{"content": [{"type": "text", "text": "hello"}, {"type": "text", "text": "world"}]}"#,
        );
        assert_eq!(content, "hello world");
    }

    #[test]
    fn extract_content_empty() {
        let content = extract_content(r#"{"foo": "bar"}"#);
        assert_eq!(content, "");
    }

    #[test]
    fn extract_content_invalid_json() {
        let content = extract_content("not json at all");
        assert_eq!(content, "");
    }

    #[test]
    fn extract_ledger_content_full() {
        let content = extract_content(
            r#"{
                "title": "Fix auth bug",
                "entryType": "bugfix",
                "status": "completed",
                "input": "fix the login issue",
                "actions": ["updated auth module", "added tests"],
                "lessons": ["always check tokens"],
                "decisions": [{"choice": "use JWT", "reason": "simpler"}],
                "files": [{"path": "src/auth.rs", "why": "main fix"}],
                "tags": ["auth", "security"]
            }"#,
        );
        assert!(content.contains("Fix auth bug"));
        assert!(content.contains("bugfix"));
        assert!(content.contains("completed"));
        assert!(content.contains("fix the login issue"));
        assert!(content.contains("updated auth module"));
        assert!(content.contains("always check tokens"));
        assert!(content.contains("use JWT"));
        assert!(content.contains("simpler"));
        assert!(content.contains("src/auth.rs"));
        assert!(content.contains("main fix"));
        assert!(content.contains("auth"));
        assert!(content.contains("security"));
    }

    #[test]
    fn extract_tool_name_from_payload() {
        assert_eq!(extract_tool_name(r#"{"toolName": "Bash"}"#), "Bash");
        assert_eq!(extract_tool_name(r#"{"name": "Read"}"#), "Read");
        assert_eq!(extract_tool_name(r#"{"foo": "bar"}"#), "");
        assert_eq!(extract_tool_name("invalid"), "");
    }
}
