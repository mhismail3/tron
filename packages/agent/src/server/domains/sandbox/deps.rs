//! Domain-specific dependency bundle for the sandbox worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        let _ = deps;
        Self
    }
}
