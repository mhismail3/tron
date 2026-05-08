//! Domain worker registration data structures.
//!
//! This module is the setup-only boundary between the broad server runtime
//! context and domain-owned worker modules. Runtime handlers receive the narrow
//! `Deps` type owned by their domain; this context is only used while building
//! worker/function registrations at startup.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::time::Instant;

use crate::engine::{FunctionDefinition, InProcessFunctionHandler, WorkerDefinition, WorkerKind};
use crate::events::EventStore;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::domains::catalog;
use crate::server::platform::codex_app::CodexAppServerManager;
use crate::server::shared::context::{AgentDeps, ServerRuntimeContext};
use crate::server::shutdown::ShutdownCoordinator;
use crate::skills::registry::SkillRegistry;

#[derive(Clone)]
pub(crate) struct DomainRegistrationContext {
    pub(crate) orchestrator: Arc<Orchestrator>,
    pub(crate) session_manager: Arc<SessionManager>,
    pub(crate) event_store: Arc<EventStore>,
    pub(crate) agent_deps: Option<AgentDeps>,
    pub(crate) skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    pub(crate) memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    pub(crate) profile_runtime: Arc<ProfileRuntime>,
    pub(crate) health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    pub(crate) shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    pub(crate) subagent_manager:
        Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    pub(crate) worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    pub(crate) context_artifacts:
        Arc<crate::server::domains::session::context::ContextArtifactsService>,
    pub(crate) origin: String,
    pub(crate) server_start_time: Instant,
    pub(crate) settings_path: PathBuf,
    pub(crate) auth_path: PathBuf,
    pub(crate) oauth_flows: Arc<
        tokio::sync::Mutex<
            std::collections::HashMap<
                String,
                crate::server::domains::auth::flows::PendingOAuthFlow,
            >,
        >,
    >,
    pub(crate) mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    pub(crate) codex_app_server: Option<Arc<CodexAppServerManager>>,
    pub(crate) device_request_broker:
        Option<Arc<crate::server::platform::device_broker::DeviceRequestBroker>>,
    pub(crate) transcription_engine: Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
    pub(crate) cron_scheduler: Option<Arc<crate::cron::CronScheduler>>,
    pub(crate) release_fetcher: Option<Arc<dyn crate::server::updater::ReleaseFetcher>>,
    pub(crate) hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    pub(crate) ws_port: Arc<AtomicU16>,
    pub(crate) onboarded_marker_path: PathBuf,
    pub(crate) updater_state_path: PathBuf,
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    pub(crate) job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    pub(crate) output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
}

impl DomainRegistrationContext {
    pub(crate) fn from_context(ctx: &ServerRuntimeContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            session_manager: Arc::clone(&ctx.session_manager),
            event_store: Arc::clone(&ctx.event_store),
            agent_deps: ctx.agent_deps.clone(),
            skill_registry: Arc::clone(&ctx.skill_registry),
            memory_registry: Arc::clone(&ctx.memory_registry),
            profile_runtime: Arc::clone(&ctx.profile_runtime),
            health_tracker: Arc::clone(&ctx.health_tracker),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
            subagent_manager: ctx.subagent_manager.clone(),
            worktree_coordinator: ctx.worktree_coordinator.clone(),
            context_artifacts: Arc::clone(&ctx.context_artifacts),
            origin: ctx.origin.clone(),
            server_start_time: ctx.server_start_time,
            settings_path: ctx.settings_path.clone(),
            auth_path: ctx.auth_path.clone(),
            oauth_flows: Arc::clone(&ctx.oauth_flows),
            mcp_router: ctx.mcp_router.clone(),
            codex_app_server: ctx.codex_app_server.clone(),
            device_request_broker: ctx.device_request_broker.clone(),
            transcription_engine: Arc::clone(&ctx.transcription_engine),
            cron_scheduler: ctx.cron_scheduler.clone(),
            release_fetcher: ctx.release_fetcher.clone(),
            hook_abort_tracker: Arc::clone(&ctx.hook_abort_tracker),
            ws_port: Arc::clone(&ctx.ws_port),
            onboarded_marker_path: ctx.onboarded_marker_path.clone(),
            updater_state_path: ctx.updater_state_path.clone(),
            engine_host: ctx.engine_host.clone(),
            process_manager: ctx.process_manager.clone(),
            job_manager: ctx.job_manager.clone(),
            output_buffer_registry: ctx.output_buffer_registry.clone(),
        }
    }
}

#[derive(Clone)]
pub(crate) struct DomainFunctionRegistration {
    pub(crate) definition: FunctionDefinition,
    pub(crate) handler: Arc<dyn InProcessFunctionHandler>,
}

#[derive(Clone)]
pub(crate) struct DomainWorkerModule {
    pub(crate) worker: WorkerDefinition,
    pub(crate) functions: Vec<DomainFunctionRegistration>,
    pub(crate) stream_topics: &'static [&'static str],
}

pub(crate) fn domain_worker_module(
    namespace: &'static str,
    stream_topics: &'static [&'static str],
    functions: Vec<DomainFunctionRegistration>,
) -> crate::engine::Result<DomainWorkerModule> {
    let worker = WorkerDefinition::new(
        catalog::worker_id(namespace)?,
        WorkerKind::InProcess,
        catalog::actor_id(catalog::SYSTEM_OWNER_ACTOR)?,
        catalog::grant_id(catalog::SYSTEM_AUTHORITY_GRANT)?,
    )
    .with_namespace_claim(namespace);
    Ok(DomainWorkerModule {
        worker,
        functions,
        stream_topics,
    })
}
