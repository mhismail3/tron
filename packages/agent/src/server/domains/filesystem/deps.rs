//! Domain-specific dependency bundle for the filesystem worker.

use crate::server::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainRegistrationContext) -> Self {
        Self
    }
}
