use super::*;
mod append_order_counters;
mod pagination_filters;
mod payload_blob_resolution;
mod reconstruction_state;
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::SessionEvent;
use serde_json::Value;
use serde_json::json;

fn setup() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        .unwrap();
    run_migrations(&conn).unwrap();

    // Create workspace and session
    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/tmp/test', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn
}

fn make_event(
    id: &str,
    seq: i64,
    event_type: EventType,
    parent_id: Option<&str>,
    payload: Value,
) -> SessionEvent {
    SessionEvent {
        id: id.to_string(),
        parent_id: parent_id.map(String::from),
        session_id: "sess_1".to_string(),
        workspace_id: "ws_1".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        event_type,
        sequence: seq,
        checksum: None,
        payload,
    }
}
