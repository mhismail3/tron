//! Domain-specific dependency bundle for the tools worker.

use super::*;

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
