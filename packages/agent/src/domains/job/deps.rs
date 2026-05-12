//! Domain-specific dependency bundle for the job worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) job_manager:
        Option<Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    pub(super) process_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            job_manager: deps.job_manager.clone(),
            orchestrator: deps.orchestrator.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            process_manager: deps.process_manager.clone(),
        }
    }
}
