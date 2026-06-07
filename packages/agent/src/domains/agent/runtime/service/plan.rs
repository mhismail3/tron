use super::{AtomicI64, PromptEngineCausality, PromptRequest, StartedRun};
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
    pub(super) health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    pub(super) event_store: Arc<crate::domains::session::event_store::EventStore>,
    pub(super) shutdown_token: Option<tokio_util::sync::CancellationToken>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) engine_causality: Option<PromptEngineCausality>,
    pub(super) sequence_counter: Option<Arc<AtomicI64>>,
    pub(super) server_origin: String,
    pub(super) run_id: String,
    pub(super) model: String,
    pub(super) working_dir: String,
    pub(super) request: PromptRequest,
}
