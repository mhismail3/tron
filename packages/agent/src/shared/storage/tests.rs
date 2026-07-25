use super::*;
use chrono::Utc;
use rusqlite::{Connection, params};

#[test]
fn managed_hygiene_policy_uses_bounded_diagnostic_scope() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(path);

    let retention = runtime.retention_run(true).unwrap();
    let budget = runtime.enforce_size_budget().unwrap();

    assert_eq!(retention.diagnostic_retention_days, 7);
    assert_eq!(DIAGNOSTIC_RETENTION_DAYS, 7);
    assert_eq!(DATABASE_STORAGE_BUDGET_MB, 512);
    assert_eq!(budget.max_database_bytes, 512 * 1024 * 1024);
}

#[test]
fn owned_payload_refs_inline_small_and_blob_large_payloads() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();

    let small = serde_json::json!({"hello": "world"});
    let small_stored = store_json_value(
        &conn,
        &small,
        &StorePayloadOptions::new("test_owner", "row-small", "payload", "audit")
            .with_inline_threshold(100),
    )
    .unwrap();
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&small_stored).unwrap(),
        small
    );

    let large = serde_json::json!({"items": vec!["same"; 64]});
    let large_stored = store_json_value(
        &conn,
        &large,
        &StorePayloadOptions::new("test_owner", "row-large", "payload", "audit")
            .with_inline_threshold(32),
    )
    .unwrap();
    assert!(large_stored.contains(PAYLOAD_REF_ENVELOPE_KEY));
    assert_eq!(
        resolve_stored_json_value(&conn, &large_stored).unwrap(),
        large
    );

    let refs: i64 = conn
        .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
            row.get(0)
        })
        .unwrap();
    let blobs: i64 = conn
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(refs, 2);
    assert_eq!(blobs, 1);
}

#[test]
fn payload_schema_drift_fails_closed_without_mutating_the_existing_table() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    conn.execute_batch(
        "CREATE TABLE blobs (
            id TEXT PRIMARY KEY,
            hash TEXT NOT NULL UNIQUE,
            ref_count INTEGER NOT NULL DEFAULT 1
         );",
    )
    .unwrap();

    let error = ensure_storage_schema(&conn).unwrap_err();

    assert!(
        error
            .to_string()
            .contains("storage schema drift: table blobs missing column content"),
        "unexpected error: {error:#}"
    );
    let blobs: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'blobs'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        blobs, 1,
        "schema verification must preserve the preexisting table"
    );
}

#[test]
fn dangling_payload_blob_refs_fail_storage_integrity_checks() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();
    conn.execute(
        "INSERT INTO storage_payload_refs (
           id, owner_kind, owner_id, field_name, payload_hash, payload_blob_id,
           payload_preview, payload_size_bytes, payload_kind, redaction_level,
           retention_class, created_at
         ) VALUES (
           'payload_ref_dangling', 'test_owner', 'row-1', 'payload',
           'hash', 'missing_blob', '{}', 2, 'application/json', 'redacted',
           'audit', ?1
         )",
        params![Utc::now().to_rfc3339()],
    )
    .unwrap();

    let error = ensure_storage_schema(&conn).unwrap_err();

    assert!(
        error
            .to_string()
            .contains("storage payload integrity failed"),
        "unexpected error: {error:#}"
    );
}

#[test]
fn blob_backed_payload_resolution_verifies_owner_hash_and_size() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();
    let value = serde_json::json!({"large":"verified".repeat(128)});
    let stored = store_json_value(
        &conn,
        &value,
        &StorePayloadOptions::new("worker_invocation", "run-1", "output", "audit")
            .with_inline_threshold(1),
    )
    .unwrap();
    assert_eq!(
        resolve_owned_json_value(&conn, "worker_invocation", "run-1", "output", &stored).unwrap(),
        value
    );

    conn.execute(
        "UPDATE storage_payload_refs SET payload_hash='tampered'
         WHERE owner_kind='worker_invocation' AND owner_id='run-1'",
        [],
    )
    .unwrap();
    let error = resolve_owned_json_value(&conn, "worker_invocation", "run-1", "output", &stored)
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("does not match its durable owner"),
        "{error:#}"
    );
}

#[test]
fn inline_payload_resolution_verifies_requested_owner_hash_and_size() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();
    let value = serde_json::json!({"small":"verified"});
    let stored = store_json_value(
        &conn,
        &value,
        &StorePayloadOptions::new("worker_invocation", "run-inline", "output", "audit"),
    )
    .unwrap();
    assert!(!stored.contains(PAYLOAD_REF_ENVELOPE_KEY));
    assert_eq!(
        resolve_owned_json_value(&conn, "worker_invocation", "run-inline", "output", &stored,)
            .unwrap(),
        value
    );

    let error =
        resolve_owned_json_value(&conn, "worker_invocation", "another-run", "output", &stored)
            .unwrap_err();
    assert!(error.to_string().contains("is missing"), "{error:#}");
    conn.execute(
        "UPDATE storage_payload_refs SET payload_size_bytes=payload_size_bytes+1
         WHERE owner_kind='worker_invocation' AND owner_id='run-inline'",
        [],
    )
    .unwrap();
    let error =
        resolve_owned_json_value(&conn, "worker_invocation", "run-inline", "output", &stored)
            .unwrap_err();
    assert!(error.to_string().contains("size or SHA-256"), "{error:#}");
}

#[test]
fn owned_payload_cleanup_repairs_refcounts_and_prunes_only_unowned_blobs() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();
    let value = serde_json::json!({"same":"content".repeat(128)});
    for owner in ["run-1", "run-2"] {
        store_json_value(
            &conn,
            &value,
            &StorePayloadOptions::new("worker_invocation", owner, "output", "audit")
                .with_inline_threshold(1),
        )
        .unwrap();
    }
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );

    assert_eq!(
        delete_owned_payload_refs(&conn, "worker_invocation", "run-1").unwrap(),
        1
    );
    assert_eq!(delete_unowned_blobs(&conn).unwrap(), 0);
    assert_eq!(
        conn.query_row("SELECT ref_count FROM blobs", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        1
    );

    assert_eq!(
        delete_owned_payload_refs(&conn, "worker_invocation", "run-2").unwrap(),
        1
    );
    assert_eq!(delete_unowned_blobs(&conn).unwrap(), 1);
}

#[test]
fn checkpoint_and_export_use_one_active_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(&path);
    let conn = runtime.open_connection().unwrap();
    conn.execute(
        "CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)",
        [],
    )
    .unwrap();
    conn.execute("INSERT INTO sample (value) VALUES ('x')", [])
        .unwrap();
    drop(conn);

    let checkpoint = runtime.checkpoint().unwrap();
    assert_eq!(checkpoint.database_path, path);

    let snapshot = dir.path().join("snapshots").join("tron-snapshot.sqlite");
    let export = runtime.export_snapshot(&snapshot).unwrap();
    assert!(export.snapshot_bytes > 0);
    assert!(snapshot.exists());
}

#[test]
fn retention_prunes_verbose_ios_logs_and_unowned_blobs_but_keeps_owned_blobs() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(&path);
    let conn = runtime.open_connection().unwrap();
    conn.execute_batch(
        "CREATE TABLE logs (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           timestamp TEXT NOT NULL,
           level TEXT NOT NULL,
           component TEXT NOT NULL
         );",
    )
    .unwrap();
    let blob_id = store_content_blob(&conn, b"unreferenced payload", "text/plain").unwrap();
    conn.execute(
        "UPDATE blobs SET ref_count = 0 WHERE id = ?1",
        params![blob_id],
    )
    .unwrap();
    let owned = store_json_bytes(
        &conn,
        br#"{"large":"owned"}"#,
        &StorePayloadOptions::new("engine_invocation", "inv_1", "result", "audit")
            .with_inline_threshold(1),
    )
    .unwrap();
    assert!(owned.contains(PAYLOAD_REF_ENVELOPE_KEY));
    conn.execute(
        "INSERT INTO logs (timestamp, level, component) VALUES (?1, 'debug', 'ios.Engine')",
        params![(Utc::now() - chrono::Duration::days(10)).to_rfc3339()],
    )
    .unwrap();
    drop(conn);

    let report = maintenance::retention_run(&path, false, 1).unwrap();
    assert_eq!(report.rows_deleted, 1);
    assert_eq!(report.blobs_deleted, 1);
    assert_eq!(report.payload_refs_deleted, 0);
    let remaining_blobs: i64 = runtime
        .open_connection()
        .unwrap()
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(remaining_blobs, 1);
}

#[test]
fn retention_prunes_expired_payload_refs_and_their_now_unowned_blobs() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(&path);
    let conn = runtime.open_connection().unwrap();
    let stored = store_json_bytes(
        &conn,
        br#"{"diagnostic":"expired"}"#,
        &StorePayloadOptions::new("diagnostic", "expired-row", "payload", "pending")
            .with_inline_threshold(1)
            .with_expires_at(Some((Utc::now() - chrono::Duration::days(1)).to_rfc3339())),
    )
    .unwrap();
    assert!(stored.contains(PAYLOAD_REF_ENVELOPE_KEY));
    drop(conn);

    let report = runtime.retention_run(false).unwrap();

    assert_eq!(report.payload_refs_deleted, 1);
    assert_eq!(report.blobs_deleted, 1);
    let conn = runtime.open_connection().unwrap();
    let refs: i64 = conn
        .query_row("SELECT COUNT(*) FROM storage_payload_refs", [], |row| {
            row.get(0)
        })
        .unwrap();
    let blobs: i64 = conn
        .query_row("SELECT COUNT(*) FROM blobs", [], |row| row.get(0))
        .unwrap();
    assert_eq!(refs, 0);
    assert_eq!(blobs, 0);
}

#[test]
fn size_budget_runs_safe_retention_and_checkpoint_without_dropping_audit_refs() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(&path);
    let conn = runtime.open_connection().unwrap();
    conn.execute_batch(
        "CREATE TABLE logs (
           id INTEGER PRIMARY KEY AUTOINCREMENT,
           timestamp TEXT NOT NULL,
           level TEXT NOT NULL,
           component TEXT NOT NULL
         );
         CREATE TABLE filler (payload BLOB NOT NULL);",
    )
    .unwrap();
    conn.execute(
        "INSERT INTO filler (payload) VALUES (?1)",
        params![vec![7_u8; 2 * 1024 * 1024]],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO logs (timestamp, level, component) VALUES (?1, 'debug', 'ios.Engine')",
        params![(Utc::now() - chrono::Duration::days(10)).to_rfc3339()],
    )
    .unwrap();
    let owned = store_json_bytes(
        &conn,
        br#"{"audit":"must stay"}"#,
        &StorePayloadOptions::new("engine_invocation", "inv_budget", "result", "audit")
            .with_inline_threshold(1),
    )
    .unwrap();
    assert!(owned.contains(PAYLOAD_REF_ENVELOPE_KEY));
    drop(conn);

    let report = maintenance::enforce_size_budget(&path, 1, 1).unwrap();
    assert!(report.over_limit);
    assert!(report.retention.is_some());
    assert!(report.checkpoint.is_some());

    let conn = runtime.open_connection().unwrap();
    let audit_refs: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM storage_payload_refs
             WHERE owner_kind = 'engine_invocation'
               AND owner_id = 'inv_budget'
               AND retention_class = 'audit'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(audit_refs, 1);
}
