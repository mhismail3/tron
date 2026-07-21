//! Domain-specific dependency bundle for the agent worker.

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::model::responder::ModelResponderFactory;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::session::event_store::EventStore;
use crate::domains::settings::SettingsRuntime;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) auth_path: PathBuf,
    pub(super) responder_factory: Option<Arc<dyn ModelResponderFactory>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) origin: String,
    pub(super) settings_runtime: Arc<SettingsRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) shutdown_coordinator:
        Option<Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            responder_factory: deps.responder_factory.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            origin: deps.origin.clone(),
            settings_runtime: deps.settings_runtime.clone(),
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
            settings: self.settings_runtime.current().settings.clone(),
            shutdown_coordinator: self.shutdown_coordinator.clone(),
            engine_host: self.engine_host.clone(),
            origin: self.origin.clone(),
        }
    }
}
