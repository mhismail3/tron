use super::{CausalContext, InvocationId, RwLock};
use crate::engine::Invocation;
use crate::skills::registry::SkillRegistry;
use serde::Serialize;
use std::sync::Arc;

#[derive(Clone)]
pub struct PromptRuntimeDeps {
    pub orchestrator: Arc<crate::runtime::orchestrator::orchestrator::Orchestrator>,
    pub session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    pub event_store: Arc<crate::events::EventStore>,
    pub context_artifacts: Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub skill_registry: Arc<RwLock<SkillRegistry>>,
    pub memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    pub profile_runtime: Arc<crate::runtime::ProfileRuntime>,
    pub health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    pub shutdown_coordinator: Option<Arc<crate::server::shutdown::ShutdownCoordinator>>,
    pub subagent_manager:
        Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    pub worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    pub process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    pub engine_host: crate::engine::EngineHostHandle,
    pub origin: String,
}

#[derive(Clone)]
pub struct PromptEngineCausality {
    pub(super) context: CausalContext,
    pub(super) parent_invocation_id: Option<InvocationId>,
}

impl PromptEngineCausality {
    #[must_use]
    pub fn from_invocation(invocation: &Invocation) -> Self {
        Self {
            context: invocation.causal_context.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PromptDrainOutcome {
    pub drained: bool,
    pub count: usize,
    pub run_id: Option<String>,
    pub reason: Option<String>,
}

impl PromptDrainOutcome {
    pub(super) fn drained(run_id: String, count: usize) -> Self {
        Self {
            drained: true,
            count,
            run_id: Some(run_id),
            reason: None,
        }
    }

    pub(super) fn not_drained(reason: impl Into<String>) -> Self {
        Self {
            drained: false,
            count: 0,
            run_id: None,
            reason: Some(reason.into()),
        }
    }
}
