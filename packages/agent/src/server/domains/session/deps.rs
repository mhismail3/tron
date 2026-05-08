//! Domain-specific dependency bundle for the session worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) context_artifacts:
        Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) shutdown_coordinator: Option<Arc<crate::server::shutdown::ShutdownCoordinator>>,
    pub(super) worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            context_artifacts: deps.context_artifacts.clone(),
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_test_context(
        ctx: &crate::server::shared::context::ServerCapabilityContext,
    ) -> Self {
        Self::from_engine(&DomainSetupContext::from_context(ctx))
    }
}
