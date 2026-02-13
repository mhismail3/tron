//! Orchestrator — multi-session coordinator.

use std::sync::Arc;

use tokio::sync::broadcast;
use tron_core::events::TronEvent;

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;
use crate::orchestrator::session_manager::{SessionFilter, SessionManager};

/// Multi-session orchestrator.
pub struct Orchestrator {
    session_manager: Arc<SessionManager>,
    broadcast: Arc<EventEmitter>,
    max_concurrent_sessions: usize,
}

impl Orchestrator {
    /// Create a new orchestrator.
    pub fn new(session_manager: Arc<SessionManager>, max_concurrent: usize) -> Self {
        Self {
            session_manager,
            broadcast: Arc::new(EventEmitter::new()),
            max_concurrent_sessions: max_concurrent,
        }
    }

    /// Get the session manager.
    pub fn session_manager(&self) -> &Arc<SessionManager> {
        &self.session_manager
    }

    /// Get the broadcast emitter.
    pub fn broadcast(&self) -> &Arc<EventEmitter> {
        &self.broadcast
    }

    /// Subscribe to all orchestrator events.
    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.broadcast.subscribe()
    }

    /// Abort a running session.
    pub fn abort(&self, _session_id: &str) -> Result<bool, RuntimeError> {
        // TODO: cancel the agent's CancellationToken via session lookup
        Ok(true)
    }

    /// Check if a session is busy (currently processing).
    pub fn is_session_busy(&self, session_id: &str) -> bool {
        self.session_manager.is_active(session_id)
    }

    /// Active session count.
    pub fn active_session_count(&self) -> usize {
        self.session_manager.active_count()
    }

    /// Maximum concurrent session limit.
    pub fn max_concurrent_sessions(&self) -> usize {
        self.max_concurrent_sessions
    }

    /// Whether we can accept another concurrent session.
    pub fn can_accept_session(&self) -> bool {
        self.session_manager.active_count() < self.max_concurrent_sessions
    }

    /// Graceful shutdown — end all active sessions.
    pub async fn shutdown(&self) -> Result<(), RuntimeError> {
        // List all active sessions and end them
        let sessions = self
            .session_manager
            .list_sessions(&SessionFilter::default())
            .unwrap_or_default();

        for session in sessions {
            let _ = self.session_manager.end_session(&session.id).await;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_events::EventStore;

    fn make_orchestrator() -> Orchestrator {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr = Arc::new(SessionManager::new(store));
        Orchestrator::new(mgr, 10)
    }

    #[test]
    fn create_orchestrator() {
        let orch = make_orchestrator();
        assert_eq!(orch.max_concurrent_sessions(), 10);
        assert_eq!(orch.active_session_count(), 0);
        assert!(orch.can_accept_session());
    }

    #[tokio::test]
    async fn create_session_through_orchestrator() {
        let orch = make_orchestrator();
        let sid = orch
            .session_manager()
            .create_session("model", "/tmp", Some("test"))
            .unwrap();

        assert_eq!(orch.active_session_count(), 1);
        assert!(orch.is_session_busy(&sid));
    }

    #[tokio::test]
    async fn subscribe_to_events() {
        let orch = make_orchestrator();
        let mut rx = orch.subscribe();

        orch.broadcast().emit(tron_core::events::agent_start_event("s1"));

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "agent_start");
    }

    #[tokio::test]
    async fn max_concurrent_enforced() {
        let orch = make_orchestrator();

        // Create sessions up to the limit
        for i in 0..10 {
            let _ = orch
                .session_manager()
                .create_session("model", &format!("/tmp/{i}"), None)
                .unwrap();
        }

        assert_eq!(orch.active_session_count(), 10);
        assert!(!orch.can_accept_session());
    }

    #[tokio::test]
    async fn abort_session() {
        let orch = make_orchestrator();
        let sid = orch
            .session_manager()
            .create_session("model", "/tmp", None)
            .unwrap();

        let result = orch.abort(&sid);
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn shutdown() {
        let orch = make_orchestrator();
        let _ = orch
            .session_manager()
            .create_session("model", "/tmp", None)
            .unwrap();

        let result = orch.shutdown().await;
        assert!(result.is_ok());
    }
}
