//! Domain-specific dependency bundle for the notifications worker.

use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) notify_delegate:
        Arc<dyn crate::domains::capability_support::implementations::traits::NotifyDelegate>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            notify_delegate: deps.capability_support_config.notify_delegate.clone(),
        }
    }
}
