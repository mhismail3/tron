pub(super) use super::super::{CreateSessionRequest, Deps, SessionCommandService};
pub(super) use crate::domains::session::event_store::EventStore;
pub(super) use crate::shared::server::test_support::make_test_context;

pub(super) fn set_last_activity(store: &EventStore, session_id: &str, rfc3339: &str) {
    let conn = store.pool().get().unwrap();
    conn.execute(
        "UPDATE sessions SET last_activity_at = ?1 WHERE id = ?2",
        rusqlite::params![rfc3339, session_id],
    )
    .unwrap();
}
