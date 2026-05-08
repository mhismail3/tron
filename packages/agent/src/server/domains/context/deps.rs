//! Domain-specific dependency bundle for the context worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) agent_deps: Option<crate::server::shared::context::AgentDeps>,
    pub(super) context_artifacts:
        Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub(super) event_store: Arc<EventStore>,
    pub(super) memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    pub(super) subagent_manager:
        Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            agent_deps: deps.agent_deps.clone(),
            context_artifacts: deps.context_artifacts.clone(),
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
