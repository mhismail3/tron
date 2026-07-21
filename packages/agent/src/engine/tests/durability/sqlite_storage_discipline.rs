use super::*;

use rusqlite::Connection;

use crate::engine::durability::state::SqliteEngineStateStore;

fn assert_shared_storage_schema(path: &std::path::Path) {
    let conn = Connection::open(path).unwrap();
    let table_exists: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='storage_checkpoints')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(table_exists);
}

fn drifted_storage_path(dir: &tempfile::TempDir, name: &str) -> std::path::PathBuf {
    let path = dir.path().join(name);
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch("CREATE TABLE storage_checkpoints (id INTEGER PRIMARY KEY);")
        .unwrap();
    path
}

fn ledger_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineLedgerStore::open(&path) {
        Ok(_) => panic!("ledger constructor accepted drifted shared storage schema"),
        Err(error) => error,
    }
}

fn stream_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineStreamStore::open(&path) {
        Ok(_) => panic!("stream constructor accepted drifted shared storage schema"),
        Err(error) => error,
    }
}

fn state_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineStateStore::open(&path) {
        Ok(_) => panic!("state constructor accepted drifted shared storage schema"),
        Err(error) => error,
    }
}

#[test]
fn sqlite_durability_constructors_create_shared_storage_schema_first() {
    let dir = tempfile::tempdir().unwrap();

    let ledger_path = dir.path().join("ledger.sqlite");
    {
        let _store = SqliteEngineLedgerStore::open(&ledger_path).unwrap();
    }
    assert_shared_storage_schema(&ledger_path);

    let stream_path = dir.path().join("stream.sqlite");
    {
        let _store = SqliteEngineStreamStore::open(&stream_path).unwrap();
    }
    assert_shared_storage_schema(&stream_path);

    let state_path = dir.path().join("state.sqlite");
    {
        let _store = SqliteEngineStateStore::open(&state_path).unwrap();
    }
    assert_shared_storage_schema(&state_path);
}

#[test]
fn sqlite_durability_constructors_refuse_shared_storage_schema_drift() {
    let dir = tempfile::tempdir().unwrap();

    let ledger = ledger_error(drifted_storage_path(&dir, "ledger-drift.sqlite"));
    assert!(ledger.to_string().contains("storage schema drift"));

    let stream = stream_error(drifted_storage_path(&dir, "stream-drift.sqlite"));
    assert!(stream.to_string().contains("storage schema drift"));

    let state = state_error(drifted_storage_path(&dir, "state-drift.sqlite"));
    assert!(state.to_string().contains("storage schema drift"));
}
