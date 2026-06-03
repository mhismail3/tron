//! Domain-specific dependency bundle for the self-extension worker.

use crate::domains::worker::DomainRegistrationContext;
use crate::engine::EngineHostHandle;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
    }
}
