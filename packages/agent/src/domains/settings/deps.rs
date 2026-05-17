//! Domain-specific dependency bundle for the settings worker.

use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) mcp_router: Option<Arc<tokio::sync::RwLock<crate::domains::mcp::router::McpRouter>>>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) settings_path: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            mcp_router: deps.mcp_router.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            settings_path: deps.settings_path.clone(),
        }
    }
}
