//! Domain-specific dependency bundle for the memory worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) server_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            server_context: deps.server_context.clone(),
        }
    }
}
