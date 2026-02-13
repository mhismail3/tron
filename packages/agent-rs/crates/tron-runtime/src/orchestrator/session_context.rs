//! Per-session mutable state holder.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use tokio::sync::RwLock;
use tron_events::EventStore;

use crate::orchestrator::event_persister::EventPersister;

/// Per-session runtime state.
pub struct SessionContext {
    /// Session identifier.
    pub session_id: String,
    /// Event persister for this session.
    pub persister: EventPersister,
    /// Whether the session is currently processing a prompt.
    is_processing: AtomicBool,
    /// Timestamp of last activity.
    last_activity: RwLock<Instant>,
}

impl SessionContext {
    /// Create a new session context.
    pub fn new(session_id: String, event_store: Arc<EventStore>) -> Self {
        let persister = EventPersister::new(event_store, session_id.clone());
        Self {
            session_id,
            persister,
            is_processing: AtomicBool::new(false),
            last_activity: RwLock::new(Instant::now()),
        }
    }

    /// Whether the session is processing a prompt.
    pub fn is_processing(&self) -> bool {
        self.is_processing.load(Ordering::Relaxed)
    }

    /// Set the processing flag.
    pub fn set_processing(&self, processing: bool) {
        self.is_processing.store(processing, Ordering::Relaxed);
    }

    /// Update last activity timestamp.
    pub async fn touch(&self) {
        let mut guard = self.last_activity.write().await;
        *guard = Instant::now();
    }

    /// Get the elapsed time since last activity.
    pub async fn idle_duration(&self) -> std::time::Duration {
        let guard = self.last_activity.read().await;
        guard.elapsed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store() -> Arc<EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn initial_state() {
        let store = make_store();
        let ctx = SessionContext::new("s1".into(), store);
        assert_eq!(ctx.session_id, "s1");
        assert!(!ctx.is_processing());
    }

    #[tokio::test]
    async fn processing_flag() {
        let store = make_store();
        let ctx = SessionContext::new("s1".into(), store);

        ctx.set_processing(true);
        assert!(ctx.is_processing());

        ctx.set_processing(false);
        assert!(!ctx.is_processing());
    }

    #[tokio::test]
    async fn touch_updates_activity() {
        let store = make_store();
        let ctx = SessionContext::new("s1".into(), store);

        tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
        let d1 = ctx.idle_duration().await;
        assert!(d1.as_millis() >= 10);

        ctx.touch().await;
        let d2 = ctx.idle_duration().await;
        assert!(d2 < d1);
    }
}
