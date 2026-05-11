//! Domain-specific dependency bundle for the session worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) shutdown_coordinator: Option<Arc<crate::app::shutdown::ShutdownCoordinator>>,
    pub(super) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            context_artifacts: deps.context_artifacts.clone(),
            event_store: deps.event_store.clone(),
            engine_host: deps.engine_host.clone(),
            orchestrator: deps.orchestrator.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn from_test_context(
        ctx: &crate::shared::server::context::ServerRuntimeContext,
    ) -> Self {
        Self::from_engine(&DomainRegistrationContext::from_context(ctx))
    }
}
