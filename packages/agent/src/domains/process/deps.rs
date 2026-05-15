//! Domain-specific dependency bundle for the process worker.

use std::sync::Arc;

use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(crate) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: Arc::clone(&deps.event_store),
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(
        event_store: Arc<crate::domains::session::event_store::EventStore>,
    ) -> Self {
        Self {
            event_store,
            worktree_coordinator: None,
        }
    }
}
