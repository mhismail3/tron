//! Domain-specific dependency bundle for the agent worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) agent_deps: Option<crate::server::shared::context::AgentDeps>,
    pub(super) context_artifacts:
        Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub(super) device_request_broker:
        Option<Arc<crate::server::platform::device_broker::DeviceRequestBroker>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    pub(super) hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    pub(super) job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(super) memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) origin: String,
    pub(super) output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub(super) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    pub(super) shutdown_coordinator: Option<Arc<crate::server::shutdown::ShutdownCoordinator>>,
    pub(super) subagent_manager:
        Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    pub(super) worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            agent_deps: deps.agent_deps.clone(),
            context_artifacts: deps.context_artifacts.clone(),
            device_request_broker: deps.device_request_broker.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            health_tracker: deps.health_tracker.clone(),
            hook_abort_tracker: deps.hook_abort_tracker.clone(),
            job_manager: deps.job_manager.clone(),
            memory_registry: deps.memory_registry.clone(),
            orchestrator: deps.orchestrator.clone(),
            origin: deps.origin.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            process_manager: deps.process_manager.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            skill_registry: deps.skill_registry.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            subagent_manager: deps.subagent_manager.clone(),
            worktree_coordinator: deps.worktree_coordinator.clone(),
        }
    }

    pub(super) fn prompt_runtime(
        &self,
    ) -> crate::server::domains::agent::runtime::service::PromptRuntimeDeps {
        crate::server::domains::agent::runtime::service::PromptRuntimeDeps {
            orchestrator: self.orchestrator.clone(),
            session_manager: self.session_manager.clone(),
            event_store: self.event_store.clone(),
            context_artifacts: self.context_artifacts.clone(),
            skill_registry: self.skill_registry.clone(),
            memory_registry: self.memory_registry.clone(),
            profile_runtime: self.profile_runtime.clone(),
            health_tracker: self.health_tracker.clone(),
            shutdown_coordinator: self.shutdown_coordinator.clone(),
            subagent_manager: self.subagent_manager.clone(),
            worktree_coordinator: self.worktree_coordinator.clone(),
            process_manager: self.process_manager.clone(),
            job_manager: self.job_manager.clone(),
            output_buffer_registry: self.output_buffer_registry.clone(),
            hook_abort_tracker: self.hook_abort_tracker.clone(),
            engine_host: self.engine_host.clone(),
            origin: self.origin.clone(),
        }
    }
}
