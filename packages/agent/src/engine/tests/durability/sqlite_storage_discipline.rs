use super::*;

use rusqlite::{Connection, params};

use crate::engine::durability::queue::SqliteEngineQueueStore;
use crate::engine::durability::resources::SqliteEngineResourceStore;
use crate::engine::durability::state::SqliteEngineStateStore;

fn assert_storage_generation(path: &std::path::Path) {
    let conn = Connection::open(path).unwrap();
    let marker: String = conn
        .query_row(
            "SELECT value FROM storage_metadata WHERE key = ?1",
            params![crate::shared::storage::STORAGE_GENERATION_KEY],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(marker, crate::shared::storage::CURRENT_STORAGE_GENERATION);
}

fn drifted_storage_path(dir: &tempfile::TempDir, name: &str) -> std::path::PathBuf {
    let path = dir.path().join(name);
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch("CREATE TABLE storage_metadata (key TEXT PRIMARY KEY);")
        .unwrap();
    path
}

fn ledger_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineLedgerStore::open(&path) {
        Ok(_) => panic!("ledger constructor accepted drifted shared storage schema"),
        Err(error) => error,
    }
}

fn queue_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineQueueStore::open(&path) {
        Ok(_) => panic!("queue constructor accepted drifted shared storage schema"),
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

fn resource_error(path: std::path::PathBuf) -> EngineError {
    match SqliteEngineResourceStore::open(&path) {
        Ok(_) => panic!("resource constructor accepted drifted shared storage schema"),
        Err(error) => error,
    }
}

#[test]
fn sqlite_durability_constructors_create_shared_storage_metadata_first() {
    let dir = tempfile::tempdir().unwrap();

    let ledger_path = dir.path().join("ledger.sqlite");
    {
        let _store = SqliteEngineLedgerStore::open(&ledger_path).unwrap();
    }
    assert_storage_generation(&ledger_path);

    let queue_path = dir.path().join("queue.sqlite");
    {
        let _store = SqliteEngineQueueStore::open(&queue_path).unwrap();
    }
    assert_storage_generation(&queue_path);

    let stream_path = dir.path().join("stream.sqlite");
    {
        let _store = SqliteEngineStreamStore::open(&stream_path).unwrap();
    }
    assert_storage_generation(&stream_path);

    let state_path = dir.path().join("state.sqlite");
    {
        let _store = SqliteEngineStateStore::open(&state_path).unwrap();
    }
    assert_storage_generation(&state_path);

    let resource_path = dir.path().join("resource.sqlite");
    {
        let _store = SqliteEngineResourceStore::open(&resource_path).unwrap();
    }
    assert_storage_generation(&resource_path);
}

#[test]
fn sqlite_durability_constructors_refuse_shared_storage_schema_drift() {
    let dir = tempfile::tempdir().unwrap();

    let ledger = ledger_error(drifted_storage_path(&dir, "ledger-drift.sqlite"));
    assert!(ledger.to_string().contains("storage schema drift"));

    let queue = queue_error(drifted_storage_path(&dir, "queue-drift.sqlite"));
    assert!(queue.to_string().contains("storage schema drift"));

    let stream = stream_error(drifted_storage_path(&dir, "stream-drift.sqlite"));
    assert!(stream.to_string().contains("storage schema drift"));

    let state = state_error(drifted_storage_path(&dir, "state-drift.sqlite"));
    assert!(state.to_string().contains("storage schema drift"));

    let resource = resource_error(drifted_storage_path(&dir, "resource-drift.sqlite"));
    assert!(resource.to_string().contains("storage schema drift"));
}
