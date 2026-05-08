//! Domain-specific dependency bundle for the repo worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }
}
