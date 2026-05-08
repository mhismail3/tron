//! Domain-specific dependency bundle for the sandbox worker.

use std::sync::Arc;

use crate::engine::EngineHostHandle;
use crate::server::domains::sandbox::service::SandboxWorkerProcessStore;
use crate::server::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: EngineHostHandle,
    pub(crate) origin: String,
    pub(crate) worker_processes: Arc<SandboxWorkerProcessStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            origin: deps.origin.clone(),
            worker_processes: Arc::new(SandboxWorkerProcessStore::default()),
        }
    }
}
