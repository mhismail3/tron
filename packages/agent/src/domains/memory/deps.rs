//! Domain-specific dependency bundle for the memory worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
            subagent_manager: deps.subagent_manager.clone(),
        }
    }
}
