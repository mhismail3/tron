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
        CREATE TABLE blobs (
            id TEXT PRIMARY KEY,
            hash TEXT NOT NULL UNIQUE,
            content BLOB NOT NULL,
            mime_type TEXT NOT NULL DEFAULT 'text/plain',
            uncompressed_size INTEGER NOT NULL,
            size_compressed INTEGER NOT NULL,
            compression TEXT NOT NULL DEFAULT 'none',
            created_at TEXT NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 1
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
fn write_batch_blobs_large_structured_data() {
    let conn = create_test_db();
    let mut entry = make_entry("debug", 20, "Engine", "large data");
    entry.data = Some(
        serde_json::json!({
            "items": vec!["same payload"; 2048],
        })
        .to_string(),
    );
    write_batch(&conn, &[entry]).unwrap();

    let data: String = conn
        .query_row("SELECT data FROM logs WHERE id = 1", [], |row| row.get(0))
        .unwrap();
    let data: serde_json::Value = serde_json::from_str(&data).unwrap();
    let payload_ref = &data[crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY];
    assert!(payload_ref["payloadBlobId"].as_str().is_some());
    assert!(payload_ref["payloadPreview"].as_str().is_some());
    assert_eq!(
        payload_ref["retentionClass"].as_str(),
        Some("diagnostic_verbose")
    );
    let expires_at: Option<String> = conn
        .query_row(
            "SELECT expires_at FROM storage_payload_refs WHERE owner_kind = 'log_entry'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(expires_at.is_some());
    let blob_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(blob_count, 1);
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
        .query_row("SELECT error_message FROM logs WHERE id = 1", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(err_msg.as_deref(), Some("Connection refused"));
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
        guard
            .batch
            .push(make_entry("info", 30, "Test", "pending 1"));
        guard
            .batch
            .push(make_entry("info", 30, "Test", "pending 2"));
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

    assert_eq!(visitor.error_message.as_deref(), Some("Connection refused"));
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
                    tracing::field::FieldSet::new(&[], tracing::callsite::Identifier(&CALLSITE)),
                    tracing::metadata::Kind::EVENT,
                )
            });
        &META
    }
}
