use super::*;
use chrono::Utc;
use rusqlite::{Connection, params};
use std::fs;

#[test]
fn archives_retired_files_once() {
    let dir = tempfile::tempdir().unwrap();
    let active = dir.path().join(UNIFIED_DB_FILENAME);
    fs::write(dir.path().join("log.db"), b"log").unwrap();
    fs::write(dir.path().join("engine-ledger.sqlite"), b"ledger").unwrap();

    let report = archive_retired_database_files(&active).unwrap();
    assert!(report.moved_any());
    assert_eq!(report.files.len(), 2);
    assert!(!dir.path().join("log.db").exists());
    assert!(!dir.path().join("engine-ledger.sqlite").exists());
    assert!(
        report
            .archive_dir
            .as_ref()
            .expect("archive dir")
            .join("log.db")
            .exists()
    );

    let second = archive_retired_database_files(&active).unwrap();
    assert!(!second.moved_any());
}

#[test]
fn incompatible_active_database_is_archived_for_modular_engine_generation() {
    let dir = tempfile::tempdir().unwrap();
    let active = dir.path().join(UNIFIED_DB_FILENAME);
    {
        let conn = Connection::open(&active).unwrap();
        conn.execute_batch("CREATE TABLE old_shape (id INTEGER PRIMARY KEY);")
            .unwrap();
    }
    fs::write(wal_path(&active), b"wal").unwrap();
    fs::write(shm_path(&active), b"shm").unwrap();

    let report = prepare_active_database(&active).unwrap();
    assert!(report.moved_any());
    assert!(!active.exists());
    assert!(!wal_path(&active).exists());
    assert!(!shm_path(&active).exists());
    let archive_dir = report.archive_dir.unwrap();
    let archive_name = archive_dir
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap();
    assert!(archive_name.starts_with(CURRENT_STORAGE_GENERATION));
    assert!(archive_dir.join(UNIFIED_DB_FILENAME).exists());
}

#[test]
fn current_generation_database_is_not_archived() {
    let dir = tempfile::tempdir().unwrap();
    let active = dir.path().join(UNIFIED_DB_FILENAME);
    let runtime = StorageRuntime::new(&active);
    let conn = runtime.open_connection().unwrap();
    drop(conn);

    let report = prepare_active_database(&active).unwrap();
    assert!(!report.moved_any());
    assert!(active.exists());
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

    let report = runtime.retention_run(false, 1).unwrap();
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

    let report = runtime.enforce_size_budget(1, 1).unwrap();
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
