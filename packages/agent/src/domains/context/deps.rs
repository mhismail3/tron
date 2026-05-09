//! Domain-specific dependency bundle for the context worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::session::event_store::EventStore;
use crate::domains::skills::registry::SkillRegistry;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) memory_registry:
        Arc<parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    pub(super) subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            context_artifacts: deps.context_artifacts.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            memory_registry: deps.memory_registry.clone(),
            orchestrator: deps.orchestrator.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            skill_registry: deps.skill_registry.clone(),
            subagent_manager: deps.subagent_manager.clone(),
        }
    }
}
