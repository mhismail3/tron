use super::{AtomicI64, PromptEngineCausality, PromptRequest, RwLock, StartedRun};
use crate::domains::skills::registry::SkillRegistry;
use std::sync::Arc;

pub(crate) struct PromptRunPlan {
    pub(super) started_run: StartedRun,
    pub(super) orchestrator:
        Arc<crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator>,
    pub(super) session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    pub(super) broadcast: Arc<crate::domains::agent::runner::EventEmitter>,
    pub(super) provider_factory:
        Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
    pub(super) guardrails:
        Option<Arc<parking_lot::Mutex<crate::domains::agent::runner::guardrails::GuardrailEngine>>>,
    pub(super) health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    pub(super) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(super) context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    pub(super) skill_registry: Arc<RwLock<SkillRegistry>>,
    pub(super) memory_registry:
        Arc<parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>>,
    pub(super) profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    pub(super) subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
    pub(super) shutdown_token: Option<tokio_util::sync::CancellationToken>,
    pub(super) worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    pub(super) process_manager:
        Option<Arc<dyn crate::domains::tools::implementations::traits::ProcessManagerOps>>,
    pub(super) job_manager:
        Option<Arc<dyn crate::domains::tools::implementations::traits::JobManagerOps>>,
    pub(super) output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    pub(super) hook_abort_tracker:
        Arc<crate::domains::agent::runner::hooks::abort_tracker::HookAbortTracker>,
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
