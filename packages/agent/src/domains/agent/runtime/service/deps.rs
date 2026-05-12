use super::{CausalContext, FunctionId, FunctionRevision, InvocationId, RwLock};
use crate::domains::skills::registry::SkillRegistry;
use crate::engine::Invocation;
use serde::Serialize;
use std::sync::Arc;

#[derive(Clone)]
pub struct PromptRuntimeDeps {
    pub orchestrator: Arc<crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator>,
    pub session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    pub event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub context_artifacts: Arc<crate::domains::session::context::ContextArtifactsService>,
    pub skill_registry: Arc<RwLock<SkillRegistry>>,
    pub memory_registry:
        Arc<parking_lot::Mutex<crate::domains::agent::runner::memory::MemoryRegistry>>,
    pub profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    pub health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    pub shutdown_coordinator: Option<Arc<crate::app::shutdown::ShutdownCoordinator>>,
    pub subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
    pub worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    pub process_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    pub job_manager:
        Option<Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>>,
    pub output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    pub hook_abort_tracker:
        Arc<crate::domains::agent::runner::hooks::abort_tracker::HookAbortTracker>,
    pub engine_host: crate::engine::EngineHostHandle,
    pub origin: String,
}

#[derive(Clone)]
pub struct PromptEngineCausality {
    pub(super) context: CausalContext,
    pub(super) parent_invocation_id: Option<InvocationId>,
    pub(super) invocation_id: InvocationId,
    pub(super) function_id: FunctionId,
    pub(super) expected_function_revision: Option<FunctionRevision>,
    pub(super) idempotency_key: Option<String>,
}

impl PromptEngineCausality {
    #[must_use]
    pub fn from_invocation(invocation: &Invocation) -> Self {
        Self {
            context: invocation.causal_context.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            expected_function_revision: invocation.expected_function_revision,
            idempotency_key: invocation.causal_context.idempotency_key.clone(),
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
