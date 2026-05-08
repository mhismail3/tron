//! Domain-specific dependency bundle for the git worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) worktree_deps: crate::server::domains::worktree::Deps,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            worktree_deps: crate::server::domains::worktree::Deps::from_engine(deps),
        }
    }
}
