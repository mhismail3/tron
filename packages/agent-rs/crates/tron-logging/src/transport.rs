//! `SQLite` write transport for `tracing` events.
//!
//! [`SqliteTransport`] implements [`tracing_subscriber::Layer`] to capture log
//! events and write them to the `logs` + `logs_fts` tables in batched
//! transactions.
//!
//! # Batching Strategy
//!
//! - Events are accumulated in an internal buffer.
//! - **Immediate flush** when level is warn, error, or fatal (`level_num` >= 40).
//! - **Threshold flush** when the batch reaches `batch_size` (default 100).
//! - **Periodic flush** via a Tokio interval task (default 1 second).
//! - All flushes write the entire batch in a single `SQLite` transaction.
//!
//! # Span Context
//!
//! Context fields (`session_id`, `workspace_id`, `component`, `trace_id`,
//! `parent_trace_id`, `depth`) are propagated via tracing span fields.
//! The transport walks the span stack for each event to collect context.

use std::sync::{Arc, Mutex};

use rusqlite::Connection;
use tracing::field::{Field, Visit};
use tracing::Subscriber;
use tracing_subscriber::layer::Context;
use tracing_subscriber::registry::LookupSpan;
use tracing_subscriber::Layer;

use crate::types::LogLevel;

/// Configuration for the `SQLite` transport.
#[derive(Clone, Debug)]
pub struct TransportConfig {
    /// Minimum level to persist (numeric). Default: 30 (info).
    pub min_level: i32,
    /// Number of entries before batch flush. Default: 100.
    pub batch_size: usize,
    /// Flush interval in milliseconds. Default: 1000.
    pub flush_interval_ms: u64,
}

impl Default for TransportConfig {
    fn default() -> Self {
        Self {
            min_level: LogLevel::Info.as_num(),
            batch_size: 100,
            flush_interval_ms: 1000,
        }
    }
}

/// A pending log entry awaiting batch flush.
#[derive(Clone, Debug)]
struct PendingEntry {
    timestamp: String,
    level: String,
    level_num: i32,
    component: String,
    message: String,
    session_id: Option<String>,
    workspace_id: Option<String>,
    event_id: Option<String>,
    turn: Option<i64>,
    trace_id: Option<String>,
    parent_trace_id: Option<String>,
    depth: Option<i32>,
    data: Option<String>,
    error_message: Option<String>,
    error_stack: Option<String>,
}

/// Inner state shared between the layer and the flush task.
struct TransportInner {
    batch: Vec<PendingEntry>,
    conn: Connection,
}

/// `SQLite` write transport for the `tracing` subscriber.
///
/// Captures log events, batches them, and writes to the `logs` table in
/// transactions. Use [`SqliteTransport::new`] to create, then register as a
/// `tracing_subscriber::Layer`.
pub struct SqliteTransport {
    inner: Arc<Mutex<TransportInner>>,
    config: TransportConfig,
}

impl SqliteTransport {
    /// Create a new transport with the given connection and config.
    ///
    /// The connection must have the `logs` and `logs_fts` tables already created
    /// (via tron-events migrations).
    pub fn new(conn: Connection, config: TransportConfig) -> Self {
        Self {
            inner: Arc::new(Mutex::new(TransportInner {
                batch: Vec::with_capacity(config.batch_size),
                conn,
            })),
            config,
        }
    }

    /// Get a handle for manual flushing and shutdown.
    pub fn handle(&self) -> TransportHandle {
        TransportHandle {
            inner: Arc::clone(&self.inner),
        }
    }

    /// Flush the current batch to `SQLite`.
    fn flush_batch(inner: &Mutex<TransportInner>) {
        let mut guard = match inner.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };

        if guard.batch.is_empty() {
            return;
        }

        let entries: Vec<PendingEntry> = guard.batch.drain(..).collect();
        let _ = write_batch(&guard.conn, &entries);
    }
}

/// Handle for flushing/shutdown from outside the layer.
#[derive(Clone)]
pub struct TransportHandle {
    inner: Arc<Mutex<TransportInner>>,
}

impl TransportHandle {
    /// Flush any pending log entries to `SQLite`.
    pub fn flush(&self) {
        SqliteTransport::flush_batch(&self.inner);
    }
}

/// Span context fields collected during event processing.
#[derive(Default)]
struct SpanContext {
    session_id: Option<String>,
    workspace_id: Option<String>,
    component: Option<String>,
    trace_id: Option<String>,
    parent_trace_id: Option<String>,
    depth: Option<i32>,
    event_id: Option<String>,
    turn: Option<i64>,
}

/// Visitor that extracts known fields from span attributes.
struct SpanFieldVisitor<'a> {
    ctx: &'a mut SpanContext,
}

impl Visit for SpanFieldVisitor<'_> {
    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "session_id" => self.ctx.session_id = Some(value.to_string()),
            "workspace_id" => self.ctx.workspace_id = Some(value.to_string()),
            "component" => self.ctx.component = Some(value.to_string()),
            "trace_id" => self.ctx.trace_id = Some(value.to_string()),
            "parent_trace_id" => self.ctx.parent_trace_id = Some(value.to_string()),
            "event_id" => self.ctx.event_id = Some(value.to_string()),
            _ => {}
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        match field.name() {
            "depth" => self.ctx.depth = i32::try_from(value).ok(),
            "turn" => self.ctx.turn = Some(value),
            _ => {}
        }
    }

    fn record_debug(&mut self, _field: &Field, _value: &dyn std::fmt::Debug) {}
}

/// Visitor that extracts fields from a tracing event.
struct EventFieldVisitor {
    message: Option<String>,
    error_message: Option<String>,
    error_stack: Option<String>,
    data: serde_json::Map<String, serde_json::Value>,
}

impl EventFieldVisitor {
    fn new() -> Self {
        Self {
            message: None,
            error_message: None,
            error_stack: None,
            data: serde_json::Map::new(),
        }
    }
}

impl Visit for EventFieldVisitor {
    fn record_str(&mut self, field: &Field, value: &str) {
        match field.name() {
            "message" => self.message = Some(value.to_string()),
            "error.message" | "error_message" => {
                self.error_message = Some(value.to_string());
            }
            "error.stack" | "error_stack" => self.error_stack = Some(value.to_string()),
            name => {
                let _ = self
                    .data
                    .insert(name.to_string(), serde_json::Value::String(value.to_string()));
            }
        }
    }

    fn record_i64(&mut self, field: &Field, value: i64) {
        let _ = self.data.insert(
            field.name().to_string(),
            serde_json::Value::Number(value.into()),
        );
    }

    fn record_bool(&mut self, field: &Field, value: bool) {
        let _ = self
            .data
            .insert(field.name().to_string(), serde_json::Value::Bool(value));
    }

    fn record_f64(&mut self, field: &Field, value: f64) {
        if let Some(n) = serde_json::Number::from_f64(value) {
            let _ = self
                .data
                .insert(field.name().to_string(), serde_json::Value::Number(n));
        }
    }

    fn record_debug(&mut self, field: &Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.message = Some(format!("{value:?}"));
        } else {
            let _ = self.data.insert(
                field.name().to_string(),
                serde_json::Value::String(format!("{value:?}")),
            );
        }
    }
}

impl<S> Layer<S> for SqliteTransport
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &tracing::Event<'_>, ctx: Context<'_, S>) {
        let level = LogLevel::from_tracing(event.metadata().level());
        let level_num = level.as_num();

        if level_num < self.config.min_level {
            return;
        }

        // Collect span context
        let mut span_ctx = SpanContext::default();
        if let Some(scope) = ctx.event_scope(event) {
            for span in scope {
                let extensions = span.extensions();
                if let Some(fields) = extensions.get::<SpanContext>() {
                    if span_ctx.session_id.is_none() {
                        span_ctx.session_id.clone_from(&fields.session_id);
                    }
                    if span_ctx.workspace_id.is_none() {
                        span_ctx.workspace_id.clone_from(&fields.workspace_id);
                    }
                    if span_ctx.component.is_none() {
                        span_ctx.component.clone_from(&fields.component);
                    }
                    if span_ctx.trace_id.is_none() {
                        span_ctx.trace_id.clone_from(&fields.trace_id);
                    }
                    if span_ctx.parent_trace_id.is_none() {
                        span_ctx.parent_trace_id.clone_from(&fields.parent_trace_id);
                    }
                    if span_ctx.depth.is_none() {
                        span_ctx.depth = fields.depth;
                    }
                    if span_ctx.event_id.is_none() {
                        span_ctx.event_id.clone_from(&fields.event_id);
                    }
                    if span_ctx.turn.is_none() {
                        span_ctx.turn = fields.turn;
                    }
                }
            }
        }

        // Extract event fields
        let mut visitor = EventFieldVisitor::new();
        event.record(&mut visitor);

        let component = span_ctx
            .component
            .unwrap_or_else(|| event.metadata().target().to_string());

        let data_json = if visitor.data.is_empty() {
            None
        } else {
            serde_json::to_string(&visitor.data).ok()
        };

        let entry = PendingEntry {
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            level: level.to_string(),
            level_num,
            component,
            message: visitor.message.unwrap_or_default(),
            session_id: span_ctx.session_id,
            workspace_id: span_ctx.workspace_id,
            event_id: span_ctx.event_id,
            turn: span_ctx.turn,
            trace_id: span_ctx.trace_id,
            parent_trace_id: span_ctx.parent_trace_id,
            depth: span_ctx.depth,
            data: data_json,
            error_message: visitor.error_message,
            error_stack: visitor.error_stack,
        };

        let should_flush = level_num >= LogLevel::Warn.as_num();

        {
            let mut guard = match self.inner.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
            guard.batch.push(entry);

            if should_flush || guard.batch.len() >= self.config.batch_size {
                let entries: Vec<PendingEntry> = guard.batch.drain(..).collect();
                let _ = write_batch(&guard.conn, &entries);
            }
        }
    }

    fn on_new_span(
        &self,
        attrs: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        ctx: Context<'_, S>,
    ) {
        let span = ctx.span(id).expect("span not found");
        let mut span_ctx = SpanContext::default();
        attrs.record(&mut SpanFieldVisitor { ctx: &mut span_ctx });
        span.extensions_mut().insert(span_ctx);
    }
}

/// Write a batch of entries to `SQLite` in a single transaction.
fn write_batch(conn: &Connection, entries: &[PendingEntry]) -> Result<(), rusqlite::Error> {
    if entries.is_empty() {
        return Ok(());
    }

    let tx = conn.unchecked_transaction()?;

    {
        let mut log_stmt = tx.prepare_cached(
            "INSERT INTO logs (timestamp, level, level_num, component, message, \
             session_id, workspace_id, event_id, turn, trace_id, \
             parent_trace_id, depth, data, error_message, error_stack) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        )?;

        let mut fts_stmt = tx.prepare_cached(
            "INSERT INTO logs_fts (log_id, session_id, component, message, error_message) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
        )?;

        for entry in entries {
            let _ = log_stmt.execute(rusqlite::params![
                entry.timestamp,
                entry.level,
                entry.level_num,
                entry.component,
                entry.message,
                entry.session_id,
                entry.workspace_id,
                entry.event_id,
                entry.turn,
                entry.trace_id,
                entry.parent_trace_id,
                entry.depth,
                entry.data,
                entry.error_message,
                entry.error_stack,
            ])?;

            let log_id = tx.last_insert_rowid();

            let _ = fts_stmt.execute(rusqlite::params![
                log_id,
                entry.session_id,
                entry.component,
                entry.message,
                entry.error_message,
            ])?;
        }
    }

    tx.commit()?;
    Ok(())
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
                id INTEGER PRIMARY KEY AUTOINCREMENT,
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
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS logs_fts USING fts5(
                log_id UNINDEXED,
                session_id UNINDEXED,
                component,
                message,
                error_message,
                tokenize='porter unicode61'
            );",
        )
        .unwrap();
        conn
    }

    fn make_entry(level: &str, level_num: i32, component: &str, msg: &str) -> PendingEntry {
        PendingEntry {
            timestamp: "2025-01-15T12:00:00.000Z".to_string(),
            level: level.to_string(),
            level_num,
            component: component.to_string(),
            message: msg.to_string(),
            session_id: None,
            workspace_id: None,
            event_id: None,
            turn: None,
            trace_id: None,
            parent_trace_id: None,
            depth: None,
            data: None,
            error_message: None,
            error_stack: None,
        }
    }

    // ── write_batch ──────────────────────────────────────────────────

    #[test]
    fn write_batch_empty() {
        let conn = create_test_db();
        write_batch(&conn, &[]).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM logs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn write_batch_single() {
        let conn = create_test_db();
        let entries = vec![make_entry("info", 30, "Test", "hello world")];
        write_batch(&conn, &entries).unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM logs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);

        // Verify fields
        let (level, component, msg): (String, String, String) = conn
            .query_row(
                "SELECT level, component, message FROM logs WHERE id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(level, "info");
        assert_eq!(component, "Test");
        assert_eq!(msg, "hello world");
    }

    #[test]
    fn write_batch_multiple() {
        let conn = create_test_db();
        let entries = vec![
            make_entry("info", 30, "A", "msg1"),
            make_entry("warn", 40, "B", "msg2"),
            make_entry("error", 50, "C", "msg3"),
        ];
        write_batch(&conn, &entries).unwrap();

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM logs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 3);
    }

    #[test]
    fn write_batch_with_all_fields() {
        let conn = create_test_db();
        let entry = PendingEntry {
            timestamp: "2025-01-15T12:00:00.000Z".to_string(),
            level: "error".to_string(),
            level_num: 50,
            component: "AgentRunner".to_string(),
            message: "Provider call failed".to_string(),
            session_id: Some("sess_123".to_string()),
            workspace_id: Some("ws_456".to_string()),
            event_id: Some("evt_789".to_string()),
            turn: Some(3),
            trace_id: Some("trace_abc".to_string()),
            parent_trace_id: Some("trace_parent".to_string()),
            depth: Some(1),
            data: Some(r#"{"attempt":2}"#.to_string()),
            error_message: Some("Connection refused".to_string()),
            error_stack: Some("Error: Connection refused\n  at ...".to_string()),
        };
        write_batch(&conn, &[entry]).unwrap();

        let sid: Option<String> = conn
            .query_row("SELECT session_id FROM logs WHERE id = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(sid.as_deref(), Some("sess_123"));

        let trace: Option<String> = conn
            .query_row("SELECT trace_id FROM logs WHERE id = 1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(trace.as_deref(), Some("trace_abc"));

        let err_msg: Option<String> = conn
            .query_row(
                "SELECT error_message FROM logs WHERE id = 1",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(err_msg.as_deref(), Some("Connection refused"));
    }

    #[test]
    fn write_batch_populates_fts() {
        let conn = create_test_db();
        let entries = vec![make_entry("info", 30, "EventStore", "Session created successfully")];
        write_batch(&conn, &entries).unwrap();

        // FTS search should find it
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs_fts WHERE logs_fts MATCH 'session'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn write_batch_fts_error_message_searchable() {
        let conn = create_test_db();
        let mut entry = make_entry("error", 50, "Provider", "API call failed");
        entry.error_message = Some("timeout after 30s".to_string());
        write_batch(&conn, &[entry]).unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM logs_fts WHERE logs_fts MATCH 'timeout'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    // ── TransportConfig ──────────────────────────────────────────────

    #[test]
    fn config_defaults() {
        let cfg = TransportConfig::default();
        assert_eq!(cfg.min_level, 30);
        assert_eq!(cfg.batch_size, 100);
        assert_eq!(cfg.flush_interval_ms, 1000);
    }

    // ── TransportHandle ──────────────────────────────────────────────

    #[test]
    fn handle_flush_empty() {
        let conn = create_test_db();
        let transport = SqliteTransport::new(conn, TransportConfig::default());
        let handle = transport.handle();
        handle.flush(); // Should not panic
    }

    #[test]
    fn handle_flush_pending_entries() {
        let conn = create_test_db();
        let transport = SqliteTransport::new(conn, TransportConfig::default());
        let handle = transport.handle();

        // Manually push entries into the batch
        {
            let mut guard = transport.inner.lock().unwrap();
            guard.batch.push(make_entry("info", 30, "Test", "pending 1"));
            guard.batch.push(make_entry("info", 30, "Test", "pending 2"));
        }

        handle.flush();

        // Verify entries were flushed
        let guard = transport.inner.lock().unwrap();
        assert!(guard.batch.is_empty());

        let count: i64 = guard
            .conn
            .query_row("SELECT COUNT(*) FROM logs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 2);
    }

    // ── EventFieldVisitor ────────────────────────────────────────────

    #[test]
    fn event_visitor_extracts_message() {
        use tracing::field::FieldSet;

        let mut visitor = EventFieldVisitor::new();
        let fields = FieldSet::new(&["message"], tracing::callsite::Identifier(&CALLSITE));
        let field = fields.field("message").unwrap();
        visitor.record_str(&field, "test message");

        assert_eq!(visitor.message.as_deref(), Some("test message"));
    }

    #[test]
    fn event_visitor_extracts_error_fields() {
        use tracing::field::FieldSet;

        let mut visitor = EventFieldVisitor::new();
        let fields = FieldSet::new(
            &["error_message", "error_stack"],
            tracing::callsite::Identifier(&CALLSITE),
        );

        let field = fields.field("error_message").unwrap();
        visitor.record_str(&field, "Connection refused");

        let field = fields.field("error_stack").unwrap();
        visitor.record_str(&field, "at line 42");

        assert_eq!(
            visitor.error_message.as_deref(),
            Some("Connection refused")
        );
        assert_eq!(visitor.error_stack.as_deref(), Some("at line 42"));
    }

    #[test]
    fn event_visitor_collects_extra_data() {
        use tracing::field::FieldSet;

        let mut visitor = EventFieldVisitor::new();
        let fields = FieldSet::new(
            &["custom_field", "count"],
            tracing::callsite::Identifier(&CALLSITE),
        );

        let field = fields.field("custom_field").unwrap();
        visitor.record_str(&field, "custom_value");

        let field = fields.field("count").unwrap();
        visitor.record_i64(&field, 42);

        assert_eq!(visitor.data.len(), 2);
        assert_eq!(visitor.data["custom_field"], "custom_value");
        assert_eq!(visitor.data["count"], 42);
    }

    // ── PendingEntry ─────────────────────────────────────────────────

    #[test]
    fn pending_entry_clone() {
        let entry = make_entry("info", 30, "Test", "msg");
        let cloned = entry.clone();
        assert_eq!(cloned.message, "msg");
        assert_eq!(cloned.component, "Test");
    }

    // ── Level-based flush behavior ───────────────────────────────────

    #[test]
    fn batch_threshold_accumulates() {
        let conn = create_test_db();
        let config = TransportConfig {
            batch_size: 5, // Small batch for testing
            ..Default::default()
        };
        let transport = SqliteTransport::new(conn, config);

        // Push 3 info entries (below threshold of 5)
        {
            let mut guard = transport.inner.lock().unwrap();
            for i in 0..3 {
                guard
                    .batch
                    .push(make_entry("info", 30, "Test", &format!("msg{i}")));
            }
        }

        // Should still be in batch (not flushed)
        let guard = transport.inner.lock().unwrap();
        assert_eq!(guard.batch.len(), 3);
    }

    // A static callsite for tests — required by tracing's FieldSet.
    static CALLSITE: TestCallsite = TestCallsite;

    struct TestCallsite;
    impl tracing::callsite::Callsite for TestCallsite {
        fn set_interest(&self, _: tracing::subscriber::Interest) {}
        fn metadata(&self) -> &tracing::Metadata<'_> {
            static META: std::sync::LazyLock<tracing::Metadata<'static>> =
                std::sync::LazyLock::new(|| {
                    tracing::Metadata::new(
                        "test",
                        "test",
                        tracing::Level::INFO,
                        None,
                        None,
                        None,
                        tracing::field::FieldSet::new(
                            &[],
                            tracing::callsite::Identifier(&CALLSITE),
                        ),
                        tracing::metadata::Kind::EVENT,
                    )
                });
            &META
        }
    }
}
