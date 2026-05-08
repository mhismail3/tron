//! Domain-specific dependency bundle for the system worker.

use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) onboarded_marker_path: PathBuf,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) origin: String,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) release_fetcher: Option<Arc<dyn crate::server::updater::ReleaseFetcher>>,
    pub(super) server_start_time: Instant,
    pub(super) updater_state_path: PathBuf,
    pub(super) ws_port: Arc<AtomicU16>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            onboarded_marker_path: deps.onboarded_marker_path.clone(),
            orchestrator: deps.orchestrator.clone(),
            origin: deps.origin.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            release_fetcher: deps.release_fetcher.clone(),
            server_start_time: deps.server_start_time,
            updater_state_path: deps.updater_state_path.clone(),
            ws_port: deps.ws_port.clone(),
        }
    }
}
