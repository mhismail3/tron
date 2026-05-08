//! Domain-specific dependency bundle for the device worker.

use crate::events::EventStore;
use crate::server::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) device_request_broker:
        Option<Arc<crate::server::platform::device_broker::DeviceRequestBroker>>,
    pub(super) event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            device_request_broker: deps.device_request_broker.clone(),
            event_store: deps.event_store.clone(),
        }
    }
}
