pub(super) use super::super::{Deps, SessionCommandService};
pub(super) use crate::domains::session::event_store::EventStore;
pub(super) use crate::shared::server::test_support::make_test_context;
use std::sync::Arc;

pub(super) fn make_store() -> Arc<EventStore> {
    let pool = crate::domains::session::event_store::new_in_memory(
        &crate::domains::session::event_store::ConnectionConfig::default(),
    )
    .unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

pub(super) fn set_last_activity(store: &EventStore, session_id: &str, rfc3339: &str) {
    let conn = store.pool().get().unwrap();
    conn.execute(
        "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
        rusqlite::params![rfc3339, session_id],
    )
    .unwrap();
}
