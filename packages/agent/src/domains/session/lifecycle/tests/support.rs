pub(super) use super::super::{CreateSessionRequest, Deps, SessionLifecycleService};
pub(super) use crate::domains::session::event_store::EventStore;
pub(super) use crate::shared::server::test_support::make_test_context;

pub(super) fn set_last_activity(store: &EventStore, session_id: &str, rfc3339: &str) {
    assert!(
        store
            .set_session_last_activity_for_test(session_id, rfc3339)
            .unwrap()
    );
}
