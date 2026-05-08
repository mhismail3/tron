//! Domain-specific dependency bundle for the model worker.

use crate::events::EventStore;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::server::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) auth_path: PathBuf,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            session_manager: deps.session_manager.clone(),
        }
    }
}
