//! Domain-specific dependency bundle for the message worker.

use crate::events::EventStore;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::server::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
        }
    }
}
