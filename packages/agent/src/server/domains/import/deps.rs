//! Domain-specific dependency bundle for the import worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) origin: String,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            origin: deps.server_context.origin.clone(),
        }
    }
}
