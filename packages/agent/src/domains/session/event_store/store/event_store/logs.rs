use crate::domains::session::event_store::errors::{EventStoreError, Result};
use crate::domains::session::event_store::redaction::redact_sensitive_content;
use crate::domains::session::event_store::sqlite::connection::PooledConnection;
use crate::shared::observability::LogLevel;

use super::EventStore;

const MAX_CLIENT_LOG_INGEST_ENTRIES: usize = 10_000;
const MAX_CLIENT_LOG_MESSAGE_BYTES: usize = 8 * 1024;

/// A single client log entry accepted by the logs capability.
#[derive(Debug, Clone, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClientLogEntry {
    /// Client-supplied event timestamp in RFC 3339 form.
    pub timestamp: String,
    /// Client-supplied level string.
    pub level: String,
    /// Client category; stored as an `ios.<category>` component.
    pub category: String,
    /// Human-readable log message.
    pub message: String,
    /// Optional session scope for owner-internal log seeding.
    #[serde(default)]
    pub session_id: Option<String>,
    /// Optional workspace scope for owner-internal log seeding.
    #[serde(default)]
    pub workspace_id: Option<String>,
    /// Optional trace scope for owner-internal log seeding.
    #[serde(default)]
    pub trace_id: Option<String>,
}

impl ClientLogEntry {
    /// Build an unscoped client log entry.
    pub fn new(
        timestamp: impl Into<String>,
        level: impl Into<String>,
        category: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            timestamp: timestamp.into(),
            level: level.into(),
            category: category.into(),
            message: message.into(),
            session_id: None,
            workspace_id: None,
            trace_id: None,
        }
    }
}

/// Result of ingesting client logs into durable storage.
#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ClientLogIngestResult {
    /// Whether ingestion completed.
    pub success: bool,
    /// Number of rows inserted after deduplication.
    pub inserted: usize,
}

/// Session scoping for recent log queries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogSessionFilter<'a> {
    /// Include logs from every session and global logs.
    All,
    /// Include only logs without a session.
    OnlyGlobal,
    /// Include only logs for the given session.
    OnlySession(&'a str),
    /// Include logs for the given session plus global logs.
    SessionAndGlobal(&'a str),
}

/// Options for querying recent persisted log entries.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RecentLogQuery<'a> {
    /// Maximum number of most-recent rows to fetch before chronological reordering.
    pub limit: i64,
    /// Optional trace id constraint.
    pub trace_id: Option<&'a str>,
    /// Optional workspace id constraint.
    pub workspace_id: Option<&'a str>,
    /// Session/global scope constraint.
    pub session_filter: LogSessionFilter<'a>,
}

impl RecentLogQuery<'_> {
    /// Build an unfiltered recent-log query.
    pub fn all(limit: i64) -> Self {
        Self {
            limit,
            trace_id: None,
            workspace_id: None,
            session_filter: LogSessionFilter::All,
        }
    }
}

/// A durable log row projected through the event-store facade.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogEntry {
    /// Monotonic log row id.
    pub id: i64,
    /// Stored timestamp.
    pub timestamp: String,
    /// Stored level string.
    pub level: String,
    /// Stored component name.
    pub component: String,
    /// Stored message.
    pub message: String,
    /// Optional owning session id.
    pub session_id: Option<String>,
    /// Optional owning workspace id.
    pub workspace_id: Option<String>,
    /// Optional trace id.
    pub trace_id: Option<String>,
    /// Optional stored error message.
    pub error_message: Option<String>,
}

impl EventStore {
    /// Insert client-supplied log rows into the unified `logs` table.
    pub fn ingest_client_logs(&self, entries: &[ClientLogEntry]) -> Result<ClientLogIngestResult> {
        if entries.len() > MAX_CLIENT_LOG_INGEST_ENTRIES {
            return Err(EventStoreError::InvalidOperation(format!(
                "Too many entries: {} (max 10000)",
                entries.len()
            )));
        }

        self.with_global_write_lock(|| {
            let mut conn = self.conn()?;
            insert_client_logs(&mut conn, entries)
        })
    }

    /// Query recent persisted logs through the storage owner boundary.
    pub fn list_recent_logs(&self, query: RecentLogQuery<'_>) -> Result<Vec<LogEntry>> {
        let conn = self.conn()?;
        query_recent_logs(&conn, query)
    }

    /// Return the current durable session count for health checks.
    pub fn session_count_for_health(&self) -> Result<i64> {
        let conn = self.conn()?;
        conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
            .map_err(EventStoreError::from)
    }
}

fn insert_client_logs(
    conn: &mut PooledConnection,
    entries: &[ClientLogEntry],
) -> Result<ClientLogIngestResult> {
    if entries.is_empty() {
        return Ok(ClientLogIngestResult {
            success: true,
            inserted: 0,
        });
    }

    let tx = conn.unchecked_transaction()?;
    let inserted = {
        let mut stmt = tx.prepare_cached(
            "INSERT OR IGNORE INTO logs (timestamp, level, level_num, component, message, \
             session_id, workspace_id, trace_id) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        )?;

        let mut count = 0usize;
        for entry in entries {
            let level = map_client_log_level(&entry.level);
            let component = format!("ios.{}", entry.category);
            let level_str = level.to_string();
            let message = redact_and_truncate_client_log_message(&entry.message);

            count += stmt.execute(rusqlite::params![
                entry.timestamp,
                level_str,
                level.as_num(),
                component,
                message.as_ref(),
                entry.session_id.as_deref(),
                entry.workspace_id.as_deref(),
                entry.trace_id.as_deref(),
            ])?;
        }
        count
    };
    tx.commit()?;

    Ok(ClientLogIngestResult {
        success: true,
        inserted,
    })
}

fn query_recent_logs(
    conn: &rusqlite::Connection,
    query: RecentLogQuery<'_>,
) -> Result<Vec<LogEntry>> {
    use rusqlite::types::Value as SqlValue;

    let mut conditions = Vec::new();
    let mut params = Vec::new();

    if let Some(trace_id) = query.trace_id {
        params.push(SqlValue::Text(trace_id.to_owned()));
        conditions.push(format!("trace_id = ?{}", params.len()));
    }

    if let Some(workspace_id) = query.workspace_id {
        params.push(SqlValue::Text(workspace_id.to_owned()));
        conditions.push(format!("workspace_id = ?{}", params.len()));
    }

    match query.session_filter {
        LogSessionFilter::All => {}
        LogSessionFilter::OnlyGlobal => {
            conditions.push("session_id IS NULL".to_owned());
        }
        LogSessionFilter::OnlySession(session_id) => {
            params.push(SqlValue::Text(session_id.to_owned()));
            conditions.push(format!("session_id = ?{}", params.len()));
        }
        LogSessionFilter::SessionAndGlobal(session_id) => {
            params.push(SqlValue::Text(session_id.to_owned()));
            conditions.push(format!(
                "(session_id IS NULL OR session_id = ?{})",
                params.len()
            ));
        }
    }

    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    };
    params.push(SqlValue::Integer(query.limit));
    let limit_param = params.len();
    let sql = format!(
        "SELECT id, timestamp, level, component, message, session_id, workspace_id, trace_id, error_message \
         FROM logs{where_clause} ORDER BY id DESC LIMIT ?{limit_param}"
    );

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(params.iter()), log_row)?;
    let mut entries = rows.collect::<std::result::Result<Vec<_>, _>>()?;
    entries.reverse();
    Ok(entries)
}

fn log_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<LogEntry> {
    Ok(LogEntry {
        id: row.get(0)?,
        timestamp: row.get(1)?,
        level: row.get(2)?,
        component: row.get(3)?,
        message: row.get(4)?,
        session_id: row.get(5)?,
        workspace_id: row.get(6)?,
        trace_id: row.get(7)?,
        error_message: row.get(8)?,
    })
}

fn map_client_log_level(s: &str) -> LogLevel {
    match s.to_lowercase().as_str() {
        "verbose" => LogLevel::Trace,
        other => LogLevel::from_str_lossy(other),
    }
}

fn truncate_client_log_message(message: &str) -> std::borrow::Cow<'_, str> {
    if message.len() <= MAX_CLIENT_LOG_MESSAGE_BYTES {
        return std::borrow::Cow::Borrowed(message);
    }
    let dropped = message.len() - MAX_CLIENT_LOG_MESSAGE_BYTES;
    let mut cut = MAX_CLIENT_LOG_MESSAGE_BYTES;
    while cut > 0 && !message.is_char_boundary(cut) {
        cut -= 1;
    }
    std::borrow::Cow::Owned(format!("{} [truncated {} bytes]", &message[..cut], dropped))
}

fn redact_and_truncate_client_log_message(message: &str) -> std::borrow::Cow<'_, str> {
    let redacted = redact_sensitive_content(message);
    if redacted == message {
        truncate_client_log_message(message)
    } else {
        std::borrow::Cow::Owned(truncate_client_log_message(&redacted).into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store() -> EventStore {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .expect("pool");
        {
            let conn = pool.get().expect("conn");
            crate::domains::session::event_store::run_migrations(&conn).expect("migrate");
        }
        EventStore::new(pool)
    }

    #[test]
    fn ingest_deduplicates_replayed_rows() {
        let store = make_store();
        let entries = vec![
            ClientLogEntry::new("2026-03-03T14:30:05.100Z", "info", "Engine", "a"),
            ClientLogEntry::new("2026-03-03T14:30:05.200Z", "info", "Engine", "b"),
        ];

        let first = store.ingest_client_logs(&entries).unwrap();
        let second = store.ingest_client_logs(&entries).unwrap();

        assert_eq!(first.inserted, 2);
        assert_eq!(second.inserted, 0);
    }

    #[test]
    fn ingest_rejects_oversized_batches() {
        let store = make_store();
        let entries: Vec<_> = (0..=MAX_CLIENT_LOG_INGEST_ENTRIES)
            .map(|i| {
                ClientLogEntry::new(
                    format!("2026-03-03T14:30:{:02}.{:03}Z", i / 1000, i % 1000),
                    "info",
                    "Engine",
                    format!("message-{i}"),
                )
            })
            .collect();

        let error = store.ingest_client_logs(&entries).unwrap_err();
        assert!(error.to_string().contains("Too many entries"));
    }

    #[test]
    fn ingest_maps_verbose_to_trace() {
        let store = make_store();
        let entries = vec![ClientLogEntry::new(
            "2026-03-03T14:30:05.100Z",
            "verbose",
            "Engine",
            "trace me",
        )];

        let result = store.ingest_client_logs(&entries).unwrap();
        assert_eq!(result.inserted, 1);

        let conn = store.conn().unwrap();
        let level_num: i32 = conn
            .query_row(
                "SELECT level_num FROM logs WHERE component = 'ios.Engine'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(level_num, 10);
    }

    #[test]
    fn truncate_short_message_is_borrow_no_alloc() {
        let short = "hello";
        let out = truncate_client_log_message(short);
        assert!(matches!(out, std::borrow::Cow::Borrowed(_)));
        assert_eq!(&*out, short);
    }

    #[test]
    fn truncate_message_at_boundary_is_not_truncated() {
        let at_limit = "x".repeat(MAX_CLIENT_LOG_MESSAGE_BYTES);
        let out = truncate_client_log_message(&at_limit);
        assert!(matches!(out, std::borrow::Cow::Borrowed(_)));
        assert_eq!(out.len(), MAX_CLIENT_LOG_MESSAGE_BYTES);
    }

    #[test]
    fn truncate_over_limit_appends_marker() {
        let big = "x".repeat(MAX_CLIENT_LOG_MESSAGE_BYTES + 500);
        let out = truncate_client_log_message(&big);
        assert!(matches!(out, std::borrow::Cow::Owned(_)));
        assert!(out.contains("[truncated 500 bytes]"));
        assert!(out.len() < MAX_CLIENT_LOG_MESSAGE_BYTES + 64);
    }

    #[test]
    fn truncate_respects_utf8_char_boundary() {
        let prefix_bytes = MAX_CLIENT_LOG_MESSAGE_BYTES - 1;
        let prefix = "a".repeat(prefix_bytes);
        let mut msg = prefix;
        msg.push_str(&"\u{1F600}".repeat(100));
        let out = truncate_client_log_message(&msg);
        assert!(std::str::from_utf8(out.as_bytes()).is_ok());
        assert!(out.contains("[truncated"));
    }

    #[test]
    fn ingest_stores_truncated_message_with_marker() {
        let store = make_store();
        let huge_message = "y".repeat(MAX_CLIENT_LOG_MESSAGE_BYTES + 100);
        let entries = vec![ClientLogEntry::new(
            "2026-03-03T14:30:05.000Z",
            "info",
            "Engine",
            huge_message,
        )];

        let result = store.ingest_client_logs(&entries).unwrap();
        assert_eq!(result.inserted, 1);

        let conn = store.conn().unwrap();
        let stored: String = conn
            .query_row(
                "SELECT message FROM logs WHERE component = 'ios.Engine'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(stored.contains("[truncated 100 bytes]"));
        assert!(stored.len() <= MAX_CLIENT_LOG_MESSAGE_BYTES + 64);
    }

    #[test]
    fn ingest_redacts_sensitive_client_log_messages_before_storage() {
        let store = make_store();
        let entries = vec![ClientLogEntry::new(
            "2026-03-03T14:30:05.000Z",
            "warn",
            "Engine",
            r#"Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789 {"apiKey":"sk-live-abcdefghijklmnopqrstuvwxyz","accessToken":"access-token-1234567890"} OAuth(code: "oauth-code-1234567890")"#,
        )];

        let result = store.ingest_client_logs(&entries).unwrap();
        assert_eq!(result.inserted, 1);

        let conn = store.conn().unwrap();
        let stored: String = conn
            .query_row(
                "SELECT message FROM logs WHERE component = 'ios.Engine'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        for secret in [
            "abcdefghijklmnopqrstuvwxyz0123456789",
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "access-token-1234567890",
            "oauth-code-1234567890",
        ] {
            assert!(!stored.contains(secret), "secret leaked to logs: {secret}");
        }
        assert!(stored.contains("Bearer ****"));
        assert!(stored.contains(r#""apiKey":"****""#));
        assert!(stored.contains(r#"code: "****""#));
    }

    #[test]
    fn redact_and_truncate_redacts_before_cutting_secret_tail() {
        let mut message = "x".repeat(MAX_CLIENT_LOG_MESSAGE_BYTES - 48);
        message.push_str(" access_token=access-token-1234567890");
        message.push(' ');
        message.push_str(&"y".repeat(128));

        let stored = redact_and_truncate_client_log_message(&message);

        assert!(!stored.contains("access-token-1234567890"));
        assert!(stored.contains("access_token=****"));
        assert!(stored.contains("[truncated"));
    }

    #[test]
    fn list_recent_logs_preserves_chronological_response_order() {
        let store = make_store();
        let entries = vec![
            ClientLogEntry::new("2026-03-03T14:30:05.100Z", "info", "Engine", "first"),
            ClientLogEntry::new("2026-03-03T14:30:05.200Z", "warn", "Engine", "second"),
        ];
        store.ingest_client_logs(&entries).unwrap();

        let logs = store.list_recent_logs(RecentLogQuery::all(2)).unwrap();
        let messages = logs
            .iter()
            .map(|entry| entry.message.as_str())
            .collect::<Vec<_>>();
        assert_eq!(messages, ["first", "second"]);
    }

    #[test]
    fn list_recent_logs_applies_trace_and_session_scope() {
        let store = make_store();
        let mut current =
            ClientLogEntry::new("2026-03-03T14:30:05.100Z", "info", "Engine", "current");
        current.session_id = Some("sess_current".to_owned());
        current.trace_id = Some("trace_1".to_owned());
        let mut global =
            ClientLogEntry::new("2026-03-03T14:30:05.200Z", "warn", "Engine", "global");
        global.trace_id = Some("trace_1".to_owned());
        let mut other = ClientLogEntry::new("2026-03-03T14:30:05.300Z", "error", "Engine", "other");
        other.session_id = Some("sess_other".to_owned());
        other.trace_id = Some("trace_1".to_owned());
        store.ingest_client_logs(&[current, global, other]).unwrap();

        let scoped = store
            .list_recent_logs(RecentLogQuery {
                limit: 10,
                trace_id: Some("trace_1"),
                workspace_id: None,
                session_filter: LogSessionFilter::SessionAndGlobal("sess_current"),
            })
            .unwrap();
        let scoped_messages = scoped
            .iter()
            .map(|entry| entry.message.as_str())
            .collect::<Vec<_>>();
        assert_eq!(scoped_messages, ["current", "global"]);

        let global_only = store
            .list_recent_logs(RecentLogQuery {
                limit: 10,
                trace_id: Some("trace_1"),
                workspace_id: None,
                session_filter: LogSessionFilter::OnlyGlobal,
            })
            .unwrap();
        let global_messages = global_only
            .iter()
            .map(|entry| entry.message.as_str())
            .collect::<Vec<_>>();
        assert_eq!(global_messages, ["global"]);
    }

    #[test]
    fn list_recent_logs_applies_workspace_scope_and_keeps_correlation_ids() {
        let store = make_store();
        let mut current =
            ClientLogEntry::new("2026-03-03T14:30:05.100Z", "info", "Engine", "current");
        current.session_id = Some("sess_current".to_owned());
        current.workspace_id = Some("workspace_a".to_owned());
        current.trace_id = Some("trace_a".to_owned());
        let mut other_workspace =
            ClientLogEntry::new("2026-03-03T14:30:05.200Z", "warn", "Engine", "other");
        other_workspace.session_id = Some("sess_current".to_owned());
        other_workspace.workspace_id = Some("workspace_b".to_owned());
        other_workspace.trace_id = Some("trace_a".to_owned());
        store
            .ingest_client_logs(&[current, other_workspace])
            .unwrap();

        let scoped = store
            .list_recent_logs(RecentLogQuery {
                limit: 10,
                trace_id: Some("trace_a"),
                workspace_id: Some("workspace_a"),
                session_filter: LogSessionFilter::OnlySession("sess_current"),
            })
            .unwrap();

        assert_eq!(scoped.len(), 1);
        assert_eq!(scoped[0].message, "current");
        assert_eq!(scoped[0].session_id.as_deref(), Some("sess_current"));
        assert_eq!(scoped[0].workspace_id.as_deref(), Some("workspace_a"));
        assert_eq!(scoped[0].trace_id.as_deref(), Some("trace_a"));
    }
}
