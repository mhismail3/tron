//! Domain-specific dependency bundle for the display worker.

use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) process_manager:
        Option<Arc<dyn crate::domains::tools::implementations::traits::ProcessManagerOps>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            process_manager: deps.process_manager.clone(),
        }
    }
}
