//! Domain-specific dependency bundle for the events worker.

use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
        }
    }
}
