#![allow(unused_results)]

use super::*;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::sqlite::repositories::event::{
    EventRepo, ListEventsOptions,
};
use crate::domains::session::event_store::sqlite::repositories::session::ListSessionsOptions;

fn setup() -> EventStore {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    EventStore::new(pool)
}

fn setup_file_backed() -> (EventStore, tempfile::TempDir) {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("test.db");
    let config = ConnectionConfig {
        pool_size: 2,
        ..ConnectionConfig::default()
    };
    let pool = connection::new_file(db_path.to_str().unwrap(), &config).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    (EventStore::new(pool), dir)
}

#[path = "tests/activity_summary.rs"]
mod activity_summary;
#[path = "tests/append_counters.rs"]
mod append_counters;
#[path = "tests/auto_sequence.rs"]
mod auto_sequence;
#[path = "tests/concurrency_worktree.rs"]
mod concurrency_worktree;
#[path = "tests/queries_state.rs"]
mod queries_state;
#[path = "tests/session_creation.rs"]
mod session_creation;
#[path = "tests/tree_sessions.rs"]
mod tree_sessions;
