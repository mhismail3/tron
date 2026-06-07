//! Domain-specific dependency bundle for the system worker.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) onboarded_marker_path: PathBuf,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) server_start_time: Instant,
    pub(super) ws_port: Arc<AtomicU16>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            onboarded_marker_path: deps.onboarded_marker_path.clone(),
            orchestrator: deps.orchestrator.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            server_start_time: deps.server_start_time,
            ws_port: deps.ws_port.clone(),
        }
    }
}
