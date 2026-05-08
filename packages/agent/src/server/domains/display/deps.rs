//! Domain-specific dependency bundle for the display worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            process_manager: deps.process_manager.clone(),
        }
    }
}
