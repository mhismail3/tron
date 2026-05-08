//! Domain-specific dependency bundle for the agent worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) agent_deps: Option<crate::server::shared::context::AgentDeps>,
    pub(super) server_context: Arc<ServerCapabilityContext>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub(super) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            agent_deps: deps.agent_deps.clone(),
            server_context: deps.server_context.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            job_manager: deps.job_manager.clone(),
            orchestrator: deps.orchestrator.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            process_manager: deps.process_manager.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            skill_registry: deps.skill_registry.clone(),
        }
    }
}
