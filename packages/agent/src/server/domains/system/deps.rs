//! Domain-specific dependency bundle for the system worker.

use super::*;

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
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            onboarded_marker_path: deps.onboarded_marker_path.clone(),
            orchestrator: deps.orchestrator.clone(),
            origin: deps.server_context.origin.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            release_fetcher: deps.server_context.release_fetcher.clone(),
            server_start_time: deps.server_start_time,
            updater_state_path: deps.updater_state_path.clone(),
            ws_port: deps.ws_port.clone(),
        }
    }
}
