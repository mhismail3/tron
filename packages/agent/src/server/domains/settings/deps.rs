//! Domain-specific dependency bundle for the settings worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) codex_app_server: Option<Arc<CodexAppServerManager>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) settings_path: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            codex_app_server: deps.codex_app_server.clone(),
            engine_host: deps.engine_host.clone(),
            mcp_router: deps.mcp_router.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            settings_path: deps.settings_path.clone(),
        }
    }
}
