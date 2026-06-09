#![allow(unused_results)]

use super::*;
use crate::domains::session::event_store::ListSessionsOptions;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::sqlite::repositories::event::{
    EventRepo, ListEventsOptions,
};

fn setup() -> EventStore {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    EventStore::new(pool)
}

mod activity_summary;
mod append_counters;
mod auto_sequence;
mod queries_state;
mod session_creation;
mod tree_sessions;
