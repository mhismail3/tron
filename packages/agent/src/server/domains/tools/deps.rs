//! Domain-specific dependency bundle for the tools worker.

use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::server::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) orchestrator: Arc<Orchestrator>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            orchestrator: deps.orchestrator.clone(),
        }
    }
}
