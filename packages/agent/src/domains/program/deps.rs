//! Dependency bundle for the program executor worker.

use std::sync::Arc;

use super::process::ProcessProgramExecutor;
use super::runtime::ProgramExecutor;
use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) executor: Arc<dyn ProgramExecutor>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            executor: Arc::new(ProcessProgramExecutor::default()),
        }
    }
}
