//! Domain-specific dependency bundle for the sandbox worker.

use std::path::PathBuf;
use std::sync::Arc;

use crate::domains::sandbox::service::SandboxWorkerProcessStore;
use crate::domains::worker::DomainRegistrationContext;
use crate::engine::EngineHostHandle;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: EngineHostHandle,
    pub(crate) origin: String,
    pub(crate) auth_path: PathBuf,
    pub(crate) worker_processes: Arc<SandboxWorkerProcessStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            origin: deps.origin.clone(),
            auth_path: deps.auth_path.clone(),
            worker_processes: Arc::new(SandboxWorkerProcessStore::default()),
        }
    }
}
