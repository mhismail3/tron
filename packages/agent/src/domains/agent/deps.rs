//! Domain-specific dependency bundle for the agent worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) agent_deps: Option<crate::shared::server::context::AgentDeps>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) origin: String,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) shutdown_coordinator:
        Option<Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            agent_deps: deps.agent_deps.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            health_tracker: deps.health_tracker.clone(),
            orchestrator: deps.orchestrator.clone(),
            origin: deps.origin.clone(),
            session_manager: deps.session_manager.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
        }
    }

    pub(super) fn prompt_runtime(
        &self,
    ) -> crate::domains::agent::runtime::service::PromptRuntimeDeps {
        crate::domains::agent::runtime::service::PromptRuntimeDeps {
            orchestrator: self.orchestrator.clone(),
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            health_tracker: self.health_tracker.clone(),
            shutdown_coordinator: self.shutdown_coordinator.clone(),
            engine_host: self.engine_host.clone(),
            origin: self.origin.clone(),
        }
    }
}
