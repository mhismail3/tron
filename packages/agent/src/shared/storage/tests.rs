use super::*;
use chrono::Utc;
use rusqlite::{Connection, params};
use std::fs;

#[test]
fn non_current_active_database_is_archived_for_modular_engine_generation() {
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
    let manifest = fs::read_to_string(archive_dir.join("archive-manifest.json")).unwrap();
    assert!(manifest.contains("active tron.sqlite missing current storage_generation marker"));
    assert!(manifest.contains(UNIFIED_DB_FILENAME));
}

#[test]
fn malformed_generation_marker_fails_closed_without_archiving_active_db() {
    let dir = tempfile::tempdir().unwrap();
    let active = dir.path().join(UNIFIED_DB_FILENAME);
    {
        let conn = Connection::open(&active).unwrap();
        conn.execute_batch(
            "CREATE TABLE storage_metadata (key TEXT PRIMARY KEY);
             INSERT INTO storage_metadata (key) VALUES ('storage_generation');",
        )
        .unwrap();
    }

    let error = prepare_active_database(&active).unwrap_err();

    assert!(
        error
            .to_string()
            .contains("failed to inspect active database generation"),
        "unexpected error: {error:#}"
    );
    assert!(
        active.exists(),
        "malformed active DB must remain inspectable"
    );
    assert!(
        !dir.path().join(ARCHIVE_DIR).exists(),
        "malformed active DB must not be moved into an archive"
    );
}

#[test]
fn orphaned_wal_and_shm_sidecars_are_archived_before_fresh_startup() {
    let dir = tempfile::tempdir().unwrap();
    let active = dir.path().join(UNIFIED_DB_FILENAME);
    fs::write(wal_path(&active), b"wal").unwrap();
    fs::write(shm_path(&active), b"shm").unwrap();

    let report = prepare_active_database(&active).unwrap();

    assert!(report.moved_any());
    assert!(!active.exists());
    assert!(!wal_path(&active).exists());
    assert!(!shm_path(&active).exists());
    let archive_dir = report.archive_dir.unwrap();
    assert!(
        archive_dir
            .join(format!("{UNIFIED_DB_FILENAME}-wal"))
            .exists()
    );
    assert!(
        archive_dir
            .join(format!("{UNIFIED_DB_FILENAME}-shm"))
            .exists()
    );
    let manifest = fs::read_to_string(archive_dir.join("archive-manifest.json")).unwrap();
    assert!(manifest.contains("orphaned WAL/SHM sidecars without active tron.sqlite"));
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
fn storage_schema_drift_fails_closed_before_marker_rewrite() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    conn.execute_batch("CREATE TABLE storage_metadata (key TEXT PRIMARY KEY);")
        .unwrap();

    let error = ensure_storage_schema(&conn).unwrap_err();

    assert!(
        error
            .to_string()
            .contains("storage schema drift: table storage_metadata missing column value"),
        "unexpected error: {error:#}"
    );
    let checkpoints: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'storage_checkpoints'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        checkpoints, 0,
        "savepoint rollback must remove tables created during failed schema setup"
    );
}

#[test]
fn wrong_storage_generation_marker_is_not_silently_rewritten() {
    let conn = Connection::open_in_memory().unwrap();
    apply_runtime_pragmas(&conn).unwrap();
    ensure_storage_schema(&conn).unwrap();
    conn.execute(
        "UPDATE storage_metadata SET value = 'older-generation'
         WHERE key = ?1",
        params![STORAGE_GENERATION_KEY],
    )
    .unwrap();

    let error = ensure_storage_schema(&conn).unwrap_err();

    assert!(
        error
            .to_string()
            .contains("storage generation marker mismatch"),
        "unexpected error: {error:#}"
    );
    let marker: String = conn
        .query_row(
            "SELECT value FROM storage_metadata WHERE key = ?1",
            params![STORAGE_GENERATION_KEY],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(marker, "older-generation");
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

    let report = runtime.retention_run(false, 7).unwrap();

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
    let retention_runs: i64 = conn
        .query_row("SELECT COUNT(*) FROM storage_retention_runs", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(refs, 0);
    assert_eq!(blobs, 0);
    assert_eq!(retention_runs, 1);
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
