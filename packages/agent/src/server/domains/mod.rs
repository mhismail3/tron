//! Domain-owned Tron capability surface.
//!
//! Each child directory is a server-owned worker namespace. Domains own their
//! canonical `namespace::function` implementations plus nearby services and
//! tests. Shared errors, params, validation, and event payloads live in
//! `server::shared`; transports only build engine requests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `catalog` | Aggregated discovery, diagnostics, and guardrail view over domain-owned contracts |
//! | `contract` | Method-agnostic builders for domain-owned `contract.rs` records |
//! | `registration` | Startup loop that registers worker modules returned by domains |
//! | domain modules | Engine-owned behavior for agent, settings, tools, MCP, git/worktree, session, cron, and the rest of Tron |
//!
//! Each domain `contract.rs` is the local source of truth for that worker's
//! function ids, schemas, authority, risk, idempotency, leases, compensation,
//! stream topics, and operation keys. Each domain `deps.rs` narrows setup
//! context into the service handles that worker actually needs. `handlers.rs`
//! is a declarative operation-key binding table backed by the shared
//! method-agnostic `bindings` helper, so completeness failures happen during
//! worker construction instead of as late runtime branches. Flow-critical
//! domains keep executable bodies in `operations/`; event-emitting domains
//! publish through typed `stream.rs` publishers for their declared topics. The
//! catalog only aggregates those records; it does not derive domain policy from
//! central method tables.
//!
//! The intended execution flow is:
//! `/engine frame -> EngineTransportRequest -> EngineTriggerRuntime -> domain
//! worker -> contract operation key -> handlers.rs -> operations/ -> narrow
//! deps/service -> engine ledger/streams/queues/approvals/leases`.
//!
//! # INVARIANT: no transport-owned behavior
//!
//! Domain methods here are canonical operation keys only. Public client
//! protocols translate into the transport-neutral engine envelope before
//! reaching these handlers.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{
    FunctionDefinition, InProcessFunctionHandler, Invocation, VisibilityScope, WorkerDefinition,
    WorkerKind,
};
use crate::events::EventStore;
use crate::prompt_library::store;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::domains::filesystem::service as filesystem_service;
use crate::server::domains::logs::client_logs::{ClientLogEntry, ClientLogsService};
use crate::server::domains::notifications::inbox::NotificationInboxService;
use crate::server::platform::codex_app::CodexAppServerManager;
use crate::server::shared::context::{AgentDeps, ServerRuntimeContext, run_blocking_task};
use crate::server::shared::error_mapping::{map_cron_error, map_event_store_error};
use crate::server::shared::errors;
use crate::server::shared::errors::{CLIENT_VERSION_UNSUPPORTED, CapabilityError, to_json_value};
use crate::server::shared::params::{
    opt_array, opt_bool, opt_string, opt_u64, require_param, require_string_param,
};
use crate::server::shared::validation::validate_string_param;
use crate::server::shutdown::ShutdownCoordinator;
use crate::skills::registry::SkillRegistry;

pub(crate) mod agent;
pub(crate) mod auth;
pub(crate) mod bindings;
pub(crate) mod blob;
pub(crate) mod browser;
pub(crate) mod catalog;
pub(crate) mod codex_app;
pub(crate) mod context;
pub(crate) mod contract;
/// Cron domain: scheduled triggers, automation state, and cron event projection.
pub mod cron;
pub(crate) mod device;
pub(crate) mod display;
pub(crate) mod events;
pub(crate) mod filesystem;
pub(crate) mod git;
pub(crate) mod import;
pub(crate) mod job;
pub(crate) mod logs;
pub(crate) mod mcp;
pub(crate) mod memory;
pub(crate) mod message;
pub(crate) mod model;
pub(crate) mod notifications;
pub(crate) mod plan;
pub(crate) mod prompt_library;
pub(crate) mod registration;
pub(crate) mod repo;
pub(crate) mod sandbox;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub(crate) mod settings;
pub(crate) mod skills;
pub(crate) mod system;
pub(crate) mod tools;
pub(crate) mod transcription;
pub(crate) mod tree;
pub(crate) mod voice_notes;
pub(crate) mod worktree;

#[derive(Clone)]
pub(crate) struct DomainRegistrationContext {
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    agent_deps: Option<AgentDeps>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    memory_registry: Arc<parking_lot::Mutex<crate::runtime::memory::MemoryRegistry>>,
    profile_runtime: Arc<ProfileRuntime>,
    health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
    context_artifacts: Arc<crate::server::domains::session::context::ContextArtifactsService>,
    origin: String,
    server_start_time: Instant,
    settings_path: PathBuf,
    auth_path: PathBuf,
    oauth_flows: Arc<
        tokio::sync::Mutex<
            std::collections::HashMap<
                String,
                crate::server::domains::auth::flows::PendingOAuthFlow,
            >,
        >,
    >,
    mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    codex_app_server: Option<Arc<CodexAppServerManager>>,
    device_request_broker: Option<Arc<crate::server::platform::device_broker::DeviceRequestBroker>>,
    transcription_engine: Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
    cron_scheduler: Option<Arc<crate::cron::CronScheduler>>,
    release_fetcher: Option<Arc<dyn crate::server::updater::ReleaseFetcher>>,
    hook_abort_tracker: Arc<crate::runtime::hooks::abort_tracker::HookAbortTracker>,
    ws_port: Arc<AtomicU16>,
    onboarded_marker_path: PathBuf,
    updater_state_path: PathBuf,
    engine_host: crate::engine::EngineHostHandle,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry:
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

pub(crate) fn all_worker_modules(
    ctx: &ServerRuntimeContext,
) -> crate::engine::Result<Vec<DomainWorkerModule>> {
    let deps = DomainRegistrationContext::from_context(ctx);
    let mut modules = vec![
        system::worker_module(&deps)?,
        codex_app::worker_module(&deps)?,
        blob::worker_module(&deps)?,
        tools::worker_module(&deps)?,
        message::worker_module(&deps)?,
        cron::worker_module(&deps)?,
        settings::worker_module(&deps)?,
        auth::worker_module(&deps)?,
        skills::worker_module(&deps)?,
        agent::worker_module(&deps)?,
        mcp::worker_module(&deps)?,
        logs::worker_module(&deps)?,
        memory::worker_module(&deps)?,
        events::worker_module(&deps)?,
        filesystem::worker_module(&deps)?,
        session::worker_module(&deps)?,
        context::worker_module(&deps)?,
        job::worker_module(&deps)?,
        notifications::worker_module(&deps)?,
        plan::worker_module(&deps)?,
        prompt_library::worker_module(&deps)?,
        tree::worker_module(&deps)?,
        repo::worker_module(&deps)?,
        import::worker_module(&deps)?,
        browser::worker_module(&deps)?,
        display::worker_module(&deps)?,
        device::worker_module(&deps)?,
        transcription::worker_module(&deps)?,
        voice_notes::worker_module(&deps)?,
        sandbox::worker_module(&deps)?,
        git::worker_module(&deps)?,
        worktree::worker_module(&deps)?,
    ];
    modules.extend(model::worker_modules(&deps)?);
    Ok(modules)
}

fn domain_worker_module(
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

fn map_store_err(e: crate::events::EventStoreError) -> CapabilityError {
    match e {
        crate::events::EventStoreError::InvalidOperation(message) => {
            CapabilityError::InvalidParams { message }
        }
        crate::events::EventStoreError::Sqlite(err) => CapabilityError::Internal {
            message: format!("Database error: {err}"),
        },
        crate::events::EventStoreError::Internal(msg) => CapabilityError::Internal { message: msg },
        other => map_event_store_error(other),
    }
}
