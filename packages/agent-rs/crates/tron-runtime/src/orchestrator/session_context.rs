//! Per-session mutable state holder.

use std::sync::Arc;

use tron_events::EventStore;

use crate::orchestrator::event_persister::EventPersister;

/// Per-session runtime state.
pub struct SessionContext {
    /// Session identifier.
    pub session_id: String,
    /// Event persister for this session (Arc-shared so callers can clone it).
    pub persister: Arc<EventPersister>,
}

impl SessionContext {
    /// Create a new session context.
    pub fn new(session_id: String, event_store: Arc<EventStore>) -> Self {
        let persister = Arc::new(EventPersister::new(event_store, session_id.clone()));
        Self {
            session_id,
            persister,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store() -> Arc<EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn initial_state() {
        let store = make_store();
        let ctx = SessionContext::new("s1".into(), store);
        assert_eq!(ctx.session_id, "s1");
    }

    #[tokio::test]
    async fn persister_is_shareable_arc() {
        let store = make_store();
        let ctx = SessionContext::new("s1".into(), store);
        let p1 = ctx.persister.clone();
        let p2 = ctx.persister.clone();
        assert!(Arc::ptr_eq(&p1, &p2));
    }
}
