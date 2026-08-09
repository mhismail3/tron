#![allow(unused_results)]

use super::*;
use crate::domains::session::event_store::ListSessionsOptions;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::repositories::event::{
    EventRepo, ListEventsOptions,
};
use crate::domains::session::event_store::sqlite::schema::ensure_schema;

fn setup() -> EventStore {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        ensure_schema(&conn).unwrap();
    }
    EventStore::new(pool)
}

mod activity_summary;
mod append_counters;
mod auto_sequence;
mod deliveries;
mod queries_state;
mod session_creation;
mod session_settings;
mod tree_sessions;
mod user_input;
