//! Log querying from `SQLite`.
//!
//! [`LogStore`] provides read-only access to persisted logs with filtering,
//! full-text search, and trace tree queries.

use std::fmt::Write as _;

use rusqlite::Connection;

use super::types::{LogEntry, LogLevel, LogQueryOptions};

/// Read-only log querying interface.
pub struct LogStore<'a> {
    conn: &'a Connection,
}

impl<'a> LogStore<'a> {
    /// Create a new log store backed by the given connection.
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// Query logs with filters.
    #[allow(clippy::cast_possible_wrap)]
    pub fn query(&self, opts: &LogQueryOptions) -> Vec<LogEntry> {
        let mut sql = String::from(
            "SELECT id, timestamp, level, level_num, component, message, \
             session_id, workspace_id, event_id, turn, trace_id, \
             parent_trace_id, depth, data, error_message, error_stack \
             FROM logs WHERE 1=1",
        );
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ref sid) = opts.session_id {
            sql.push_str(" AND session_id = ?");
            params.push(Box::new(sid.clone()));
        }
        if let Some(ref wid) = opts.workspace_id {
            sql.push_str(" AND workspace_id = ?");
            params.push(Box::new(wid.clone()));
        }
        if let Some(min_level) = opts.min_level {
            sql.push_str(" AND level_num >= ?");
            params.push(Box::new(min_level));
        }
        if let Some(ref tid) = opts.trace_id {
            sql.push_str(" AND trace_id = ?");
            params.push(Box::new(tid.clone()));
        }
        if let Some(ref components) = opts.components {
            if !components.is_empty() {
                let placeholders: Vec<String> =
                    components.iter().map(|_| "?".to_string()).collect();
                let _ = write!(sql, " AND component IN ({})", placeholders.join(", "));
                for c in components {
                    params.push(Box::new(c.clone()));
                }
            }
        }

        let order = opts.order.as_deref().unwrap_or("asc");
        let _ = write!(sql, " ORDER BY timestamp {order}");

        if let Some(limit) = opts.limit {
            sql.push_str(" LIMIT ?");
            params.push(Box::new(limit as i64));
        }
        if let Some(offset) = opts.offset {
            sql.push_str(" OFFSET ?");
            params.push(Box::new(offset as i64));
        }

        let param_refs: Vec<&dyn rusqlite::types::ToSql> =
            params.iter().map(AsRef::as_ref).collect();

        let Ok(mut stmt) = self.conn.prepare(&sql) else {
            return Vec::new();
        };

        let rows = stmt.query_map(param_refs.as_slice(), |row| Ok(row_to_entry(row)));

        match rows {
            Ok(mapped) => mapped.filter_map(Result::ok).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Get all logs for a session.
    pub fn get_session_logs(&self, session_id: &str) -> Vec<LogEntry> {
        self.query(&LogQueryOptions {
            session_id: Some(session_id.to_string()),
            order: Some("asc".to_string()),
            ..Default::default()
        })
    }

    /// Get recent errors (across all sessions).
    pub fn get_recent_errors(&self, limit: usize) -> Vec<LogEntry> {
        self.query(&LogQueryOptions {
            min_level: Some(LogLevel::Error.as_num()),
            order: Some("desc".to_string()),
            limit: Some(limit),
            ..Default::default()
        })
    }

    /// Get a trace tree (root + all descendants via `parent_trace_id`).
    pub fn get_trace_tree(&self, trace_id: &str) -> Vec<LogEntry> {
        let sql = "SELECT id, timestamp, level, level_num, component, message, \
                   session_id, workspace_id, event_id, turn, trace_id, \
                   parent_trace_id, depth, data, error_message, error_stack \
                   FROM logs WHERE trace_id = ?1 OR parent_trace_id = ?1 \
                   ORDER BY timestamp ASC";

        let Ok(mut stmt) = self.conn.prepare(sql) else {
            return Vec::new();
        };

        let rows = stmt.query_map([trace_id], |row| Ok(row_to_entry(row)));

        match rows {
            Ok(mapped) => mapped.filter_map(Result::ok).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Delete logs older than the given timestamp.
    ///
    /// Returns the number of deleted rows.
    pub fn prune_old_logs(&self, older_than: &str) -> usize {
        self.conn
            .execute("DELETE FROM logs WHERE timestamp < ?1", [older_than])
            .unwrap_or(0)
    }
}

/// Map a `SQLite` row to a [`LogEntry`].
fn row_to_entry(row: &rusqlite::Row<'_>) -> LogEntry {
    let level_str: String = row.get(2).unwrap_or_default();
    let level = LogLevel::from_str_lossy(&level_str);
    let data_str: Option<String> = row.get(13).unwrap_or(None);

    LogEntry {
        id: row.get(0).unwrap_or(0),
        timestamp: row.get(1).unwrap_or_default(),
        level,
        level_num: row.get(3).unwrap_or(0),
        component: row.get(4).unwrap_or_default(),
        message: row.get(5).unwrap_or_default(),
        session_id: row.get(6).unwrap_or(None),
        workspace_id: row.get(7).unwrap_or(None),
        event_id: row.get(8).unwrap_or(None),
        turn: row.get(9).unwrap_or(None),
        trace_id: row.get(10).unwrap_or(None),
        parent_trace_id: row.get(11).unwrap_or(None),
        depth: row.get(12).unwrap_or(None),
        data: data_str.and_then(|s| serde_json::from_str(&s).ok()),
        error_message: row.get(14).unwrap_or(None),
        error_stack: row.get(15).unwrap_or(None),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn create_test_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE logs (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL,
                level TEXT NOT NULL,
                level_num INTEGER NOT NULL,
                component TEXT NOT NULL DEFAULT '',
                message TEXT DEFAULT '',
                session_id TEXT,
                workspace_id TEXT,
                event_id TEXT,
                turn INTEGER,
                trace_id TEXT,
                parent_trace_id TEXT,
                depth INTEGER,
                data TEXT,
                error_message TEXT,
                error_stack TEXT
            );",
        )
        .unwrap();
        conn
    }

    fn insert_log(
        conn: &Connection,
        level: &str,
        level_num: i32,
        component: &str,
        msg: &str,
        session_id: Option<&str>,
    ) {
        let _ = conn
            .execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, session_id) \
             VALUES (datetime('now'), ?, ?, ?, ?, ?)",
                rusqlite::params![level, level_num, component, msg, session_id],
            )
            .unwrap();
    }

    #[test]
    fn query_all() {
        let conn = create_test_db();
        insert_log(&conn, "info", 30, "test", "hello", None);
        insert_log(&conn, "warn", 40, "test", "caution", None);

        let store = LogStore::new(&conn);
        let logs = store.query(&LogQueryOptions::default());
        assert_eq!(logs.len(), 2);
    }

    #[test]
    fn query_by_session() {
        let conn = create_test_db();
        insert_log(&conn, "info", 30, "a", "msg1", Some("sess_1"));
        insert_log(&conn, "info", 30, "a", "msg2", Some("sess_2"));
        insert_log(&conn, "info", 30, "a", "msg3", Some("sess_1"));

        let store = LogStore::new(&conn);
        let logs = store.get_session_logs("sess_1");
        assert_eq!(logs.len(), 2);
        assert!(
            logs.iter()
                .all(|l| l.session_id.as_deref() == Some("sess_1"))
        );
    }

    #[test]
    fn query_by_min_level() {
        let conn = create_test_db();
        insert_log(&conn, "debug", 20, "a", "low", None);
        insert_log(&conn, "info", 30, "a", "mid", None);
        insert_log(&conn, "error", 50, "a", "high", None);

        let store = LogStore::new(&conn);
        let logs = store.query(&LogQueryOptions {
            min_level: Some(30),
            ..Default::default()
        });
        assert_eq!(logs.len(), 2);
    }

    #[test]
    fn query_recent_errors() {
        let conn = create_test_db();
        insert_log(&conn, "info", 30, "a", "ok", None);
        insert_log(&conn, "error", 50, "a", "bad", None);
        insert_log(&conn, "fatal", 60, "a", "very bad", None);

        let store = LogStore::new(&conn);
        let errors = store.get_recent_errors(10);
        assert_eq!(errors.len(), 2);
    }

    #[test]
    fn query_with_limit_offset() {
        let conn = create_test_db();
        for i in 0..10 {
            insert_log(&conn, "info", 30, "a", &format!("msg{i}"), None);
        }

        let store = LogStore::new(&conn);
        let logs = store.query(&LogQueryOptions {
            limit: Some(3),
            offset: Some(2),
            ..Default::default()
        });
        assert_eq!(logs.len(), 3);
    }

    #[test]
    fn query_empty_table() {
        let conn = create_test_db();
        let store = LogStore::new(&conn);
        let logs = store.query(&LogQueryOptions::default());
        assert!(logs.is_empty());
    }

    #[test]
    fn prune_old_logs() {
        let conn = create_test_db();
        let _ = conn
            .execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message) \
             VALUES ('2024-01-01T00:00:00Z', 'info', 30, 'a', 'old')",
                [],
            )
            .unwrap();
        let _ = conn
            .execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message) \
             VALUES ('2025-01-01T00:00:00Z', 'info', 30, 'a', 'new')",
                [],
            )
            .unwrap();

        let store = LogStore::new(&conn);
        let deleted = store.prune_old_logs("2024-06-01T00:00:00Z");
        assert_eq!(deleted, 1);

        let remaining = store.query(&LogQueryOptions::default());
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].message, "new");
    }

    #[test]
    fn trace_tree_query() {
        let conn = create_test_db();
        let _ = conn
            .execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, trace_id) \
             VALUES ('2024-01-01T00:00:00Z', 'info', 30, 'a', 'root', 'trace_1')",
                [],
            )
            .unwrap();
        let _ = conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, trace_id, parent_trace_id) \
             VALUES ('2024-01-01T00:00:01Z', 'info', 30, 'b', 'child', 'trace_2', 'trace_1')",
            [],
        )
        .unwrap();
        let _ = conn
            .execute(
                "INSERT INTO logs (timestamp, level, level_num, component, message, trace_id) \
             VALUES ('2024-01-01T00:00:02Z', 'info', 30, 'c', 'unrelated', 'trace_3')",
                [],
            )
            .unwrap();

        let store = LogStore::new(&conn);
        let tree = store.get_trace_tree("trace_1");
        assert_eq!(tree.len(), 2);
    }

    #[test]
    fn query_by_components() {
        let conn = create_test_db();
        insert_log(&conn, "info", 30, "EventStore", "msg1", None);
        insert_log(&conn, "info", 30, "Agent", "msg2", None);
        insert_log(&conn, "info", 30, "Server", "msg3", None);

        let store = LogStore::new(&conn);
        let logs = store.query(&LogQueryOptions {
            components: Some(vec!["EventStore".to_string(), "Agent".to_string()]),
            ..Default::default()
        });
        assert_eq!(logs.len(), 2);
    }
}
