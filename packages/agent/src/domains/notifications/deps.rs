//! Domain-specific dependency bundle for the notifications worker.

use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) notify_delegate:
        Arc<dyn crate::domains::capability_support::implementations::traits::NotifyDelegate>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            notify_delegate: deps.capability_support_config.notify_delegate.clone(),
        }
    }
}
