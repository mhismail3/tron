//! Domain-specific dependency bundle for the browser worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainSetupContext) -> Self {
        Self
    }
}
