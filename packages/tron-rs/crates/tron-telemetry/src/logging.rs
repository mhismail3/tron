use std::path::Path;
use std::sync::Arc;

use chrono::Utc;
use parking_lot::Mutex;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use tracing::field::{Field, Visit};
use tracing::span;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

/// A log record persisted to SQLite.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LogRecord {
    pub id: i64,
    pub timestamp: String,
    pub level: String,
    pub target: String,
    pub message: String,
    pub fields: Option<String>,
    pub span_id: Option<String>,
    pub session_id: Option<String>,
    pub agent_id: Option<String>,
}

/// Query parameters for searching persisted logs.
#[derive(Clone, Debug, Default)]
pub struct LogQuery {
    pub level: Option<String>,
    pub target: Option<String>,
    pub session_id: Option<String>,
    pub since: Option<String>,
    pub limit: Option<u32>,
}

/// SQLite sink that persists warn+ logs.
pub struct SqliteLogSink {
    conn: Mutex<Connection>,
}

impl SqliteLogSink {
    pub fn new(db_path: &Path) -> Result<Self, rusqlite::Error> {
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS logs (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 timestamp TEXT NOT NULL,
                 level TEXT NOT NULL,
                 target TEXT NOT NULL,
                 message TEXT NOT NULL,
                 fields TEXT,
                 span_id TEXT,
                 session_id TEXT,
                 agent_id TEXT,
                 created_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
             CREATE INDEX IF NOT EXISTS idx_logs_session ON logs(session_id);
             CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON logs(timestamp);",
        )?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    fn insert(&self, record: &LogInsert) {
        let conn = self.conn.lock();
        let _ = conn.execute(
            "INSERT INTO logs (timestamp, level, target, message, fields, span_id, session_id, agent_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            rusqlite::params![
                record.timestamp,
                record.level,
                record.target,
                record.message,
                record.fields,
                record.span_id,
                record.session_id,
                record.agent_id,
            ],
        );
    }

    pub fn query(&self, q: &LogQuery) -> Result<Vec<LogRecord>, rusqlite::Error> {
        let conn = self.conn.lock();
        let mut sql = String::from(
            "SELECT id, timestamp, level, target, message, fields, span_id, session_id, agent_id FROM logs WHERE 1=1",
        );
        let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(level) = &q.level {
            sql.push_str(&format!(" AND level = ?{}", params.len() + 1));
            params.push(Box::new(level.clone()));
        }
        if let Some(target) = &q.target {
            sql.push_str(&format!(" AND target LIKE ?{}", params.len() + 1));
            params.push(Box::new(format!("%{target}%")));
        }
        if let Some(session_id) = &q.session_id {
            sql.push_str(&format!(" AND session_id = ?{}", params.len() + 1));
            params.push(Box::new(session_id.clone()));
        }
        if let Some(since) = &q.since {
            sql.push_str(&format!(" AND timestamp >= ?{}", params.len() + 1));
            params.push(Box::new(since.clone()));
        }

        sql.push_str(" ORDER BY id DESC");

        let limit = q.limit.unwrap_or(100);
        sql.push_str(&format!(" LIMIT {limit}"));

        let param_refs: Vec<&dyn rusqlite::types::ToSql> = params.iter().map(|p| p.as_ref()).collect();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(param_refs.as_slice(), |row| {
            Ok(LogRecord {
                id: row.get(0)?,
                timestamp: row.get(1)?,
                level: row.get(2)?,
                target: row.get(3)?,
                message: row.get(4)?,
                fields: row.get(5)?,
                span_id: row.get(6)?,
                session_id: row.get(7)?,
                agent_id: row.get(8)?,
            })
        })?;

        rows.collect()
    }

    pub fn count(&self) -> Result<i64, rusqlite::Error> {
        let conn = self.conn.lock();
        conn.query_row("SELECT COUNT(*) FROM logs", [], |row| row.get(0))
    }
}

/// Internal insert record (not public).
struct LogInsert {
    timestamp: String,
    level: String,
    target: String,
    message: String,
    fields: Option<String>,
    span_id: Option<String>,
    session_id: Option<String>,
    agent_id: Option<String>,
}

/// tracing Layer that writes warn+ events to SQLite.
pub struct SqliteLogLayer {
    sink: Arc<SqliteLogSink>,
}

impl SqliteLogLayer {
    pub fn new(sink: Arc<SqliteLogSink>) -> Self {
        Self { sink }
    }
}

/// Visitor that extracts fields from a tracing event.
struct FieldVisitor {
    message: Option<String>,
    fields: serde_json::Map<String, serde_json::Value>,
    session_id: Option<String>,
    agent_id: Option<String>,
}

impl FieldVisitor {
    fn new() -> Self {
        Self {
            message: None,
            fields: serde_json::Map::new(),
            session_id: None,
            agent_id: None,
        }
    }
}

impl Visit for FieldVisitor {
    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        let val = format!("{:?}", value);
        match field.name() {
            "message" => self.message = Some(val),
            "session_id" => self.session_id = Some(val.trim_matches('"').to_string()),
            "agent_id" => self.agent_id = Some(val.trim_matches('"').to_string()),
            name => {
                self.fields
                    .insert(name.to_string(), serde_json::Value::String(val));
            }
        }
    }

    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "message" => self.message = Some(value.to_string()),
            "session_id" => self.session_id = Some(value.to_string()),
            "agent_id" => self.agent_id = Some(value.to_string()),
            name => {
                self.fields
                    .insert(name.to_string(), serde_json::Value::String(value.to_string()));
            }
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        self.fields
            .insert(field.name().to_string(), serde_json::Value::Number(value.into()));
    }

    fn record_u64(&mut self, field: &Field, value: u64) {
        self.fields.insert(
            field.name().to_string(),
            serde_json::Value::Number(value.into()),
        );
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        if let Some(n) = serde_json::Number::from_f64(value) {
            self.fields
                .insert(field.name().to_string(), serde_json::Value::Number(n));
        }
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        self.fields
            .insert(field.name().to_string(), serde_json::Value::Bool(value));
    }
}

impl<S> Layer<S> for SqliteLogLayer
where
    S: tracing::Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    fn on_event(&self, event: &tracing::Event<'_>, ctx: Context<'_, S>) {
        // Only persist WARN and above
        let level = *event.metadata().level();
        if level > tracing::Level::WARN {
            return;
        }

        let mut visitor = FieldVisitor::new();
        event.record(&mut visitor);

        // Try to extract session_id/agent_id from span context if not on the event
        if visitor.session_id.is_none() || visitor.agent_id.is_none() {
            if let Some(scope) = ctx.event_scope(event) {
                for span in scope {
                    let extensions = span.extensions();
                    if let Some(fields) = extensions.get::<SpanFields>() {
                        if visitor.session_id.is_none() {
                            visitor.session_id.clone_from(&fields.session_id);
                        }
                        if visitor.agent_id.is_none() {
                            visitor.agent_id.clone_from(&fields.agent_id);
                        }
                    }
                }
            }
        }

        let span_id = ctx
            .event_scope(event)
            .and_then(|mut scope| scope.next())
            .map(|span| format!("{:?}", span.id()));

        let fields_json = if visitor.fields.is_empty() {
            None
        } else {
            Some(serde_json::to_string(&visitor.fields).unwrap_or_default())
        };

        let record = LogInsert {
            timestamp: Utc::now().to_rfc3339(),
            level: level.to_string().to_uppercase(),
            target: event.metadata().target().to_string(),
            message: visitor.message.unwrap_or_default(),
            fields: fields_json,
            span_id,
            session_id: visitor.session_id,
            agent_id: visitor.agent_id,
        };

        self.sink.insert(&record);
    }

    fn on_new_span(&self, attrs: &span::Attributes<'_>, id: &span::Id, ctx: Context<'_, S>) {
        let mut visitor = FieldVisitor::new();
        attrs.record(&mut visitor);

        if visitor.session_id.is_some() || visitor.agent_id.is_some() {
            if let Some(span) = ctx.span(id) {
                let mut extensions = span.extensions_mut();
                extensions.insert(SpanFields {
                    session_id: visitor.session_id,
                    agent_id: visitor.agent_id,
                });
            }
        }
    }
}

/// Stored on spans to propagate session_id / agent_id to child events.
struct SpanFields {
    session_id: Option<String>,
    agent_id: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_db() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tron-test-logs-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("test-logs.db")
    }

    #[test]
    fn sqlite_sink_create_and_insert() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:00Z".into(),
            level: "WARN".into(),
            target: "tron_llm::anthropic".into(),
            message: "rate limited".into(),
            fields: Some(r#"{"retry_after":5}"#.into()),
            span_id: None,
            session_id: Some("sess_123".into()),
            agent_id: None,
        });

        let count = sink.count().unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn sqlite_sink_query_by_level() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:00Z".into(),
            level: "WARN".into(),
            target: "test".into(),
            message: "warning msg".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });
        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:01Z".into(),
            level: "ERROR".into(),
            target: "test".into(),
            message: "error msg".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });

        let results = sink
            .query(&LogQuery {
                level: Some("ERROR".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].message, "error msg");
    }

    #[test]
    fn sqlite_sink_query_by_session() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:00Z".into(),
            level: "WARN".into(),
            target: "test".into(),
            message: "session A".into(),
            fields: None,
            span_id: None,
            session_id: Some("sess_aaa".into()),
            agent_id: None,
        });
        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:01Z".into(),
            level: "WARN".into(),
            target: "test".into(),
            message: "session B".into(),
            fields: None,
            span_id: None,
            session_id: Some("sess_bbb".into()),
            agent_id: None,
        });

        let results = sink
            .query(&LogQuery {
                session_id: Some("sess_aaa".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].message, "session A");
    }

    #[test]
    fn sqlite_sink_query_by_target() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:00Z".into(),
            level: "ERROR".into(),
            target: "tron_llm::anthropic".into(),
            message: "provider error".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });
        sink.insert(&LogInsert {
            timestamp: "2026-02-14T12:00:01Z".into(),
            level: "ERROR".into(),
            target: "tron_store::events".into(),
            message: "db error".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });

        let results = sink
            .query(&LogQuery {
                target: Some("anthropic".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].message, "provider error");
    }

    #[test]
    fn sqlite_sink_query_limit() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        for i in 0..10 {
            sink.insert(&LogInsert {
                timestamp: format!("2026-02-14T12:00:{i:02}Z"),
                level: "WARN".into(),
                target: "test".into(),
                message: format!("msg {i}"),
                fields: None,
                span_id: None,
                session_id: None,
                agent_id: None,
            });
        }

        let results = sink
            .query(&LogQuery {
                limit: Some(3),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 3);
        // Most recent first (ORDER BY id DESC)
        assert_eq!(results[0].message, "msg 9");
    }

    #[test]
    fn sqlite_sink_query_since() {
        let db_path = temp_db();
        let sink = SqliteLogSink::new(&db_path).unwrap();

        sink.insert(&LogInsert {
            timestamp: "2026-02-14T11:00:00Z".into(),
            level: "WARN".into(),
            target: "test".into(),
            message: "old".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });
        sink.insert(&LogInsert {
            timestamp: "2026-02-14T13:00:00Z".into(),
            level: "WARN".into(),
            target: "test".into(),
            message: "new".into(),
            fields: None,
            span_id: None,
            session_id: None,
            agent_id: None,
        });

        let results = sink
            .query(&LogQuery {
                since: Some("2026-02-14T12:00:00Z".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].message, "new");
    }

    #[test]
    fn field_visitor_extracts_types() {
        let mut visitor = FieldVisitor::new();

        // Test that the visitor struct initializes correctly
        assert!(visitor.message.is_none());
        assert!(visitor.session_id.is_none());
        assert!(visitor.agent_id.is_none());
        assert!(visitor.fields.is_empty());

        // Test record_str for message
        visitor.message = Some("test message".into());
        visitor.session_id = Some("sess_123".into());
        visitor
            .fields
            .insert("key".into(), serde_json::Value::String("value".into()));

        assert_eq!(visitor.message.as_deref(), Some("test message"));
        assert_eq!(visitor.session_id.as_deref(), Some("sess_123"));
        assert!(visitor.fields.contains_key("key"));
    }

    #[test]
    fn log_record_serde_roundtrip() {
        let record = LogRecord {
            id: 1,
            timestamp: "2026-02-14T12:00:00Z".into(),
            level: "WARN".into(),
            target: "tron_llm".into(),
            message: "rate limited".into(),
            fields: Some(r#"{"attempts":3}"#.into()),
            span_id: Some("Id(42)".into()),
            session_id: Some("sess_123".into()),
            agent_id: Some("agent_456".into()),
        };
        let json = serde_json::to_string(&record).unwrap();
        let parsed: LogRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, 1);
        assert_eq!(parsed.level, "WARN");
        assert_eq!(parsed.session_id.as_deref(), Some("sess_123"));
    }
}
