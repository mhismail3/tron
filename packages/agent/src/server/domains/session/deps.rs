//! Domain-specific dependency bundle for the session worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) auth_path: PathBuf,
    pub(super) codex_app_server: Option<Arc<CodexAppServerManager>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(super) mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    pub(super) onboarded_marker_path: PathBuf,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    pub(super) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) server_start_time: Instant,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) settings_path: PathBuf,
    pub(super) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    pub(super) ws_port: Arc<AtomicU16>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            codex_app_server: deps.codex_app_server.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            job_manager: deps.job_manager.clone(),
            mcp_router: deps.mcp_router.clone(),
            onboarded_marker_path: deps.onboarded_marker_path.clone(),
            orchestrator: deps.orchestrator.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            process_manager: deps.process_manager.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            server_start_time: deps.server_start_time,
            session_manager: deps.session_manager.clone(),
            settings_path: deps.settings_path.clone(),
            skill_registry: deps.skill_registry.clone(),
            ws_port: deps.ws_port.clone(),
        }
    }
}
