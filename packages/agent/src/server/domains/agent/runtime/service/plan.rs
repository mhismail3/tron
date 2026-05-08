use super::*;

pub(crate) struct PromptRunPlan {
    pub(super) started_run: StartedRun,
    pub(super) orchestrator: Arc<crate::runtime::orchestrator::orchestrator::Orchestrator>,
    pub(super) session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    pub(super) broadcast: Arc<crate::runtime::EventEmitter>,
    pub(super) provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
    pub(super) tool_factory: Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
    pub(super) guardrails:
        Option<Arc<parking_lot::Mutex<crate::runtime::guardrails::GuardrailEngine>>>,
    pub(super) health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    pub(super) event_store: Arc<crate::events::EventStore>,
    pub(super) context_artifacts:
        Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub(super) skill_registry: Arc<RwLock<SkillRegistry>>,
    pub(super) memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    pub(super) profile_runtime: Arc<crate::runtime::ProfileRuntime>,
    pub(super) subagent_manager:
        Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    pub(super) shutdown_token: Option<tokio_util::sync::CancellationToken>,
    pub(super) worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    pub(super) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(super) job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(super) output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub(super) hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) engine_causality: Option<PromptEngineCausality>,
    pub(super) sequence_counter: Option<Arc<AtomicI64>>,
    pub(super) server_origin: String,
    pub(super) run_id: String,
    pub(super) source: Option<String>,
    pub(super) profile: String,
    pub(super) model: String,
    pub(super) working_dir: String,
    pub(super) request: PromptRequest,
}
