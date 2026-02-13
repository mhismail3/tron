//! RPC dependency-injection context.

use std::sync::Arc;

use tron_runtime::orchestrator::orchestrator::Orchestrator;
use tron_runtime::orchestrator::session_manager::SessionManager;

/// Shared context passed to every RPC handler.
pub struct RpcContext {
    /// Multi-session orchestrator.
    pub orchestrator: Arc<Orchestrator>,
    /// Session lifecycle manager.
    pub session_manager: Arc<SessionManager>,
}

#[cfg(test)]
mod tests {
    use crate::handlers::test_helpers::make_test_context;

    #[test]
    fn context_has_orchestrator() {
        let ctx = make_test_context();
        assert_eq!(ctx.orchestrator.max_concurrent_sessions(), 10);
    }

    #[test]
    fn context_has_session_manager() {
        let ctx = make_test_context();
        assert_eq!(ctx.session_manager.active_count(), 0);
    }

    #[tokio::test]
    async fn context_session_manager_matches_orchestrator() {
        let ctx = make_test_context();
        let _ = ctx
            .session_manager
            .create_session("model", "/tmp", Some("test"))
            .unwrap();
        // Orchestrator sees it because they share the same SessionManager.
        assert_eq!(ctx.orchestrator.active_session_count(), 1);
    }
}
