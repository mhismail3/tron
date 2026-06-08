//! Session repository tests.

#![allow(unused_results)]

use super::*;
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::sqlite::repositories::workspace::{
    CreateWorkspaceOptions, WorkspaceRepo,
};

fn setup() -> (Connection, String) {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        .unwrap();
    run_migrations(&conn).unwrap();

    let ws = WorkspaceRepo::create(
        &conn,
        &CreateWorkspaceOptions {
            path: "/tmp/test",
            name: None,
        },
    )
    .unwrap();
    (conn, ws.id)
}

fn create_default_session(conn: &Connection, ws_id: &str) -> SessionRow {
    SessionRepo::create(
        conn,
        &CreateSessionOptions {
            workspace_id: ws_id,
            model: "claude-opus-4-6",
            working_directory: "/tmp/test",
            title: Some("Test Session"),
            tags: None,
            parent_session_id: None,
            fork_from_event_id: None,
        },
    )
    .unwrap()
}

mod core;
mod projections;
