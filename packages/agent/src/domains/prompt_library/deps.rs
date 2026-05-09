//! Domain-specific dependency bundle for the prompt_library worker.

use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
        }
    }
}
