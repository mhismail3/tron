//! Domain-specific dependency bundle for the model worker.

use crate::domains::agent::r#loop::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::session::event_store::EventStore;
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
