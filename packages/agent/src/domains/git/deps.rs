//! Domain-specific dependency bundle for the git worker.

use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) worktree_deps: crate::domains::worktree::Deps,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            worktree_deps: crate::domains::worktree::Deps::from_engine(deps),
        }
    }
}
