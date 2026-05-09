//! Domain-specific dependency bundle for the worktree worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
    pub(super) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            orchestrator: deps.orchestrator.clone(),
            session_manager: deps.session_manager.clone(),
            subagent_manager: deps.subagent_manager.clone(),
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }
}
