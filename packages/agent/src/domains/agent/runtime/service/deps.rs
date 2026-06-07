use super::{CausalContext, FunctionId, FunctionRevision, InvocationId};
use crate::engine::Invocation;
use std::sync::Arc;

#[derive(Clone)]
pub struct PromptRuntimeDeps {
    pub orchestrator: Arc<crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator>,
    pub session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    pub event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    pub health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    pub shutdown_coordinator: Option<Arc<crate::app::shutdown::ShutdownCoordinator>>,
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
