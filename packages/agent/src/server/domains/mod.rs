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
//! and stream topics. The catalog only aggregates those records; it does not
//! derive domain policy from central method tables.
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

use async_trait::async_trait;
use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{
    ActorKind, EngineError, FunctionDefinition, InProcessFunctionHandler, Invocation,
    PublishStreamEvent, VisibilityScope, WorkerDefinition, WorkerKind,
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
use crate::server::shared::context::{ServerCapabilityContext, run_blocking_task};
use crate::server::shared::error_mapping::{map_cron_error, map_event_store_error};
use crate::server::shared::errors;
use crate::server::shared::errors::{CLIENT_VERSION_UNSUPPORTED, CapabilityError, to_json_value};
use crate::server::shared::events::ServerEventPayload;
use crate::server::shared::params::{
    opt_array, opt_bool, opt_string, opt_u64, require_param, require_string_param,
};
use crate::server::shared::validation::validate_string_param;
use crate::skills::registry::SkillRegistry;

use crate::server::shared::error_mapping::capability_error_to_engine;

pub(crate) mod agent;
pub(crate) mod auth;
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
pub(crate) struct EngineCapabilityDeps {
    capability_context: Arc<ServerCapabilityContext>,
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    agent_deps: Option<crate::server::shared::context::AgentDeps>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    profile_runtime: Arc<ProfileRuntime>,
    server_start_time: Instant,
    settings_path: PathBuf,
    auth_path: PathBuf,
    mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    codex_app_server: Option<Arc<CodexAppServerManager>>,
    ws_port: Arc<AtomicU16>,
    onboarded_marker_path: PathBuf,
    updater_state_path: PathBuf,
    engine_host: crate::engine::EngineHostHandle,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
}

impl EngineCapabilityDeps {
    pub(crate) fn from_context(ctx: &ServerCapabilityContext) -> Self {
        Self {
            capability_context: Arc::new(ctx.clone()),
            orchestrator: Arc::clone(&ctx.orchestrator),
            session_manager: Arc::clone(&ctx.session_manager),
            event_store: Arc::clone(&ctx.event_store),
            agent_deps: ctx.agent_deps.clone(),
            skill_registry: Arc::clone(&ctx.skill_registry),
            profile_runtime: Arc::clone(&ctx.profile_runtime),
            server_start_time: ctx.server_start_time,
            settings_path: ctx.settings_path.clone(),
            auth_path: ctx.auth_path.clone(),
            mcp_router: ctx.mcp_router.clone(),
            codex_app_server: ctx.codex_app_server.clone(),
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

pub(crate) struct DomainFunctionHandler<D> {
    pub(crate) method: &'static str,
    pub(crate) deps: D,
    pub(crate) handler: DomainHandlerFn<D>,
}

#[async_trait]
impl<D> InProcessFunctionHandler for DomainFunctionHandler<D>
where
    D: Send + Sync + 'static,
{
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        (self.handler)(self.method, &invocation, &self.deps)
            .await
            .map_err(capability_error_to_engine)
    }
}

pub(crate) type DomainHandlerFn<D> = for<'a> fn(
    &'static str,
    &'a Invocation,
    &'a D,
) -> BoxFuture<'a, Result<Value, CapabilityError>>;

pub(crate) fn all_worker_modules(
    ctx: &ServerCapabilityContext,
) -> crate::engine::Result<Vec<DomainWorkerModule>> {
    let deps = EngineCapabilityDeps::from_context(ctx);
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

fn domain_worker_module<D>(
    namespace: &'static str,
    specs: Vec<catalog::CapabilitySpec>,
    deps: D,
    handler: DomainHandlerFn<D>,
) -> crate::engine::Result<DomainWorkerModule>
where
    D: Clone + Send + Sync + 'static,
{
    let worker = WorkerDefinition::new(
        catalog::worker_id(namespace)?,
        WorkerKind::InProcess,
        catalog::actor_id(catalog::SYSTEM_OWNER_ACTOR)?,
        catalog::grant_id(catalog::SYSTEM_AUTHORITY_GRANT)?,
    )
    .with_namespace_claim(namespace);
    let functions = specs
        .into_iter()
        .map(|spec| domain_function_registration(spec, deps.clone(), handler))
        .collect::<crate::engine::Result<Vec<_>>>()?;
    Ok(DomainWorkerModule {
        worker,
        functions,
        stream_topics: &[],
    })
}

fn domain_function_registration<D>(
    spec: catalog::CapabilitySpec,
    deps: D,
    handler: DomainHandlerFn<D>,
) -> crate::engine::Result<DomainFunctionRegistration>
where
    D: Clone + Send + Sync + 'static,
{
    Ok(DomainFunctionRegistration {
        definition: catalog::function_definition_for_capability(&spec),
        handler: Arc::new(DomainFunctionHandler {
            method: spec.method,
            deps: deps.clone(),
            handler,
        }),
    })
}

macro_rules! domain_handler {
    ($fn_name:ident, $module:ident) => {
        fn $fn_name<'a>(
            method: &'static str,
            invocation: &'a Invocation,
            deps: &'a $module::Deps,
        ) -> BoxFuture<'a, Result<Value, CapabilityError>> {
            Box::pin(async move { $module::handle(method, invocation, deps).await })
        }
    };
}

fn system_handler<'a>(
    method: &'static str,
    invocation: &'a Invocation,
    deps: &'a system::Deps,
) -> BoxFuture<'a, Result<Value, CapabilityError>> {
    Box::pin(async move {
        let allow_capability_context =
            matches!(invocation.causal_context.actor_kind, ActorKind::Client);
        system::handle(method, invocation, deps, allow_capability_context).await
    })
}

fn model_handler<'a>(
    method: &'static str,
    invocation: &'a Invocation,
    deps: &'a model::Deps,
) -> BoxFuture<'a, Result<Value, CapabilityError>> {
    Box::pin(async move {
        let allow_capability_context =
            matches!(invocation.causal_context.actor_kind, ActorKind::Client);
        model::handle(method, invocation, deps, allow_capability_context).await
    })
}

fn browser_handler<'a>(
    method: &'static str,
    _invocation: &'a Invocation,
    deps: &'a browser::Deps,
) -> BoxFuture<'a, Result<Value, CapabilityError>> {
    Box::pin(async move { browser::handle(method, deps).await })
}

domain_handler!(agent_handler, agent);
domain_handler!(auth_handler, auth);
domain_handler!(blob_handler, blob);
domain_handler!(codex_app_handler, codex_app);
domain_handler!(context_handler, context);
domain_handler!(cron_handler, cron);
domain_handler!(device_handler, device);
domain_handler!(display_handler, display);
domain_handler!(events_handler, events);
domain_handler!(filesystem_handler, filesystem);
domain_handler!(git_handler, git);
fn git_workflow_handler<'a>(
    method: &'static str,
    invocation: &'a Invocation,
    deps: &'a worktree::Deps,
) -> BoxFuture<'a, Result<Value, CapabilityError>> {
    Box::pin(async move { worktree::git_workflow::handle(method, invocation, deps).await })
}
domain_handler!(import_handler, import);
domain_handler!(job_handler, job);
domain_handler!(logs_handler, logs);
domain_handler!(mcp_handler, mcp);
domain_handler!(memory_handler, memory);
domain_handler!(message_handler, message);
domain_handler!(notifications_handler, notifications);
domain_handler!(plan_handler, plan);
domain_handler!(prompt_library_handler, prompt_library);
domain_handler!(repo_handler, repo);
domain_handler!(sandbox_handler, sandbox);
domain_handler!(session_handler, session);
domain_handler!(settings_handler, settings);
domain_handler!(skills_handler, skills);
domain_handler!(tool_handler, tools);
domain_handler!(transcription_handler, transcription);
domain_handler!(tree_handler, tree);
domain_handler!(voice_notes_handler, voice_notes);
domain_handler!(worktree_handler, worktree);

async fn publish_engine_stream_event(
    engine_host: &crate::engine::EngineHostHandle,
    topic: &str,
    producer: &str,
    event: ServerEventPayload,
    invocation: Option<&Invocation>,
) {
    if let Err(error) = engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: topic.to_owned(),
            payload: json!({
                "serverEvent": event.clone(),
                "__broadcastScope": event
                    .session_id
                    .as_ref()
                    .map(|session_id| json!({ "kind": "session", "sessionId": session_id }))
                    .unwrap_or_else(|| json!({ "kind": "all" })),
                "sourceEventType": event.event_type.clone(),
            }),
            visibility: VisibilityScope::System,
            session_id: invocation
                .and_then(|invocation| invocation.causal_context.session_id.clone())
                .or_else(|| event.session_id.clone()),
            workspace_id: invocation
                .and_then(|invocation| invocation.causal_context.workspace_id.clone()),
            producer: producer.to_owned(),
            trace_id: invocation.map(|invocation| invocation.causal_context.trace_id.clone()),
            parent_invocation_id: invocation.map(|invocation| invocation.id.clone()),
        })
        .await
    {
        tracing::warn!(topic, producer, error = %error, "engine stream publication failed");
    }
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
