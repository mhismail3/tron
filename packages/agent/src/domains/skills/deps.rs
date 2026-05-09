//! Domain-specific dependency bundle for the skills worker.

use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::domains::skills::registry::SkillRegistry;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) event_store: Arc<EventStore>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            session_manager: deps.session_manager.clone(),
            skill_registry: deps.skill_registry.clone(),
        }
    }
}
