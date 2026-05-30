#![allow(unused_results)]

use super::*;
use rusqlite::Connection;

fn open_memory() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;",
    )
    .unwrap();
    conn
}

fn seed_workspace_and_session(conn: &Connection, ws: &str, sess: &str) {
    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES (?1, ?2, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        rusqlite::params![ws, format!("/tmp/{ws}")],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                               created_at, last_activity_at)
         VALUES (?1, ?2, 'claude-3', '/tmp',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        rusqlite::params![sess, ws],
    )
    .unwrap();
}

#[path = "tests/devices_retired.rs"]
mod devices_retired;
#[path = "tests/mechanics.rs"]
mod mechanics;
#[path = "tests/schema_events.rs"]
mod schema_events;
#[path = "tests/sessions_logs.rs"]
mod sessions_logs;
