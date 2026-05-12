//! Domain-specific dependency bundle for the process worker.

use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainRegistrationContext) -> Self {
        Self
    }
}
