//! Canonical Tron capability surface.
//!
//! This module owns the server-specific `namespace::function` implementations
//! that the engine catalog exposes to agents, tools, triggers, and public
//! transports. Capability handlers return transport-neutral
//! [`CapabilityError`] values and plain JSON results; client protocols map
//! those values at their own transport boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `catalog` | Canonical specs, worker ownership, trigger definitions, and guardrails |
//! | `errors` / `error_mapping` | Transport-neutral capability errors and domain/engine mappers |
//! | `params` / `validation` | Payload extraction and strict schema/depth validation |
//! | domain modules | Engine-owned behavior for agent, settings, tools, MCP, git/worktree, session, cron, and the rest of Tron |
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
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{
    ActorKind, EngineError, InProcessFunctionHandler, Invocation, PublishStreamEvent,
    VisibilityScope,
};
use crate::events::EventStore;
use crate::prompt_library::store;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::capabilities::error_mapping::{map_cron_error, map_event_store_error};
use crate::server::capabilities::errors::{
    CLIENT_VERSION_UNSUPPORTED, CapabilityError, to_json_value,
};
use crate::server::capabilities::params::{
    opt_array, opt_bool, opt_string, opt_u64, require_param, require_string_param,
};
use crate::server::capabilities::validation::validate_string_param;
use crate::server::codex_app::CodexAppServerManager;
use crate::server::services::client_logs::{ClientLogEntry, ClientLogsService};
use crate::server::services::context::{ServerCapabilityContext, run_blocking_task};
use crate::server::services::events_wire::ServerEventPayload;
use crate::server::services::filesystem_service;
use crate::server::services::notification_inbox::NotificationInboxService;
use crate::skills::registry::SkillRegistry;

use crate::server::capabilities::error_mapping::capability_error_to_engine;

mod agent;
mod auth;
mod blob;
mod browser;
pub(crate) mod catalog;
mod codex_app;
mod context;
pub(crate) mod cron;
mod device;
mod display;
pub(crate) mod error_mapping;
pub(crate) mod errors;
mod events;
mod filesystem;
mod git;
mod git_workflow;
mod import;
mod job;
mod logs;
mod mcp;
mod memory;
mod message;
mod model;
mod notifications;
pub(crate) mod params;
mod plan;
mod prompt_library;
mod repo;
mod safe_reads;
mod sandbox;
pub(crate) mod schemas;
mod session;
mod settings;
mod skills;
mod system;
mod tool;
mod transcription;
mod tree;
pub(crate) mod validation;
mod voice_notes;
mod worktree;

#[derive(Clone)]
pub(crate) struct EngineCapabilityDeps {
    capability_context: Arc<ServerCapabilityContext>,
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    agent_deps: Option<crate::server::services::context::AgentDeps>,
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

pub(crate) struct CanonicalFunctionHandler {
    pub(crate) method: &'static str,
    pub(crate) deps: EngineCapabilityDeps,
}

#[async_trait]
impl InProcessFunctionHandler for CanonicalFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        capability_function_value(self.method, &invocation, &self.deps)
            .await
            .map_err(capability_error_to_engine)
    }
}

async fn publish_engine_stream_event(
    deps: &EngineCapabilityDeps,
    topic: &str,
    producer: &str,
    event: ServerEventPayload,
    invocation: Option<&Invocation>,
) {
    if let Err(error) = deps
        .engine_host
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

async fn capability_function_value(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let allow_capability_context =
        matches!(invocation.causal_context.actor_kind, ActorKind::Client);
    match method {
        "system::ping" | "system::get_info" => {
            system::handle(method, invocation, deps, allow_capability_context).await
        }
        "system::get_diagnostics"
        | "system::get_update_status"
        | "system::check_for_updates"
        | "system::shutdown" => {
            system::handle(method, invocation, deps, allow_capability_context).await
        }
        "codex_app::status" => codex_app::handle(method, invocation, deps).await,
        "blob::get" => blob::handle(method, invocation, deps).await,
        "tool::result" => tool::handle(method, invocation, deps).await,
        "message::delete" => message::handle(method, invocation, deps).await,
        "cron::list"
        | "cron::get"
        | "cron::create"
        | "cron::update"
        | "cron::delete"
        | "cron::run"
        | "cron::status"
        | "cron::get_runs"
        | "cron::scheduled_fire" => cron::handle(method, invocation, deps).await,
        "settings::get" | "settings::update" | "settings::reset_to_defaults" => {
            settings::handle(method, invocation, deps).await
        }
        "auth::get"
        | "auth::update"
        | "auth::clear"
        | "auth::oauth_begin"
        | "auth::oauth_complete"
        | "auth::rename_account"
        | "auth::set_active"
        | "auth::remove_account"
        | "auth::remove_api_key" => auth::handle(method, invocation, deps).await,
        "model::list" | "model::switch" | "config::set_reasoning_level" => {
            model::handle(method, invocation, deps, allow_capability_context).await
        }
        "skills::list" | "skills::get" | "skills::refresh" | "skills::activate"
        | "skills::deactivate" | "skills::active" => skills::handle(method, invocation, deps).await,
        "agent::prompt"
        | "agent::prompt_apply"
        | "agent::run_turn"
        | "agent::prompt_queue_drain"
        | "agent::status"
        | "agent::abort"
        | "agent::abort_tool"
        | "agent::queue_prompt"
        | "agent::dequeue_prompt"
        | "agent::clear_queue"
        | "agent::deliver_subagent_results"
        | "agent::submit_confirmation"
        | "agent::submit_answers" => agent::handle(method, invocation, deps).await,
        "mcp::status"
        | "mcp::add_server"
        | "mcp::remove_server"
        | "mcp::enable_server"
        | "mcp::disable_server"
        | "mcp::restart_server"
        | "mcp::reload"
        | "mcp::list_tools" => mcp::handle(method, invocation, deps).await,
        "logs::ingest" | "logs::recent" => logs::handle(method, invocation, deps).await,
        "memory::retain" => memory::handle(method, invocation, deps).await,
        "events::get_history" | "events::get_since" | "events::append" => {
            events::handle(method, invocation, deps).await
        }
        "events::subscribe" | "events::unsubscribe" => {
            events::handle(method, invocation, deps).await
        }
        "filesystem::list_dir" | "filesystem::get_home" | "filesystem::read_file" => {
            filesystem::handle(method, invocation, deps).await
        }
        "filesystem::create_dir" => filesystem::handle(method, invocation, deps).await,
        "session::list"
        | "session::create"
        | "session::resume"
        | "session::delete"
        | "session::fork"
        | "session::get_head"
        | "session::get_state"
        | "session::get_history"
        | "session::reconstruct"
        | "session::archive"
        | "session::unarchive"
        | "session::archive_older_than"
        | "session::export" => session::handle(method, invocation, deps).await,
        "context::get_snapshot"
        | "context::get_detailed_snapshot"
        | "context::get_audit_trace"
        | "context::should_compact"
        | "context::preview_compaction"
        | "context::can_accept_turn"
        | "context::confirm_compaction"
        | "context::clear"
        | "context::compact" => context::handle(method, invocation, deps).await,
        "job::background"
        | "job::cancel"
        | "job::background_apply"
        | "job::cancel_apply"
        | "job::list"
        | "job::subscribe"
        | "job::unsubscribe" => job::handle(method, invocation, deps).await,
        "notifications::list" | "notifications::mark_read" | "notifications::mark_all_read" => {
            notifications::handle(method, invocation, deps).await
        }
        "plan::enter" | "plan::exit" | "plan::get_state" => {
            plan::handle(method, invocation, deps).await
        }
        "prompt_library::history_list"
        | "prompt_library::history_delete"
        | "prompt_library::history_clear"
        | "prompt_library::snippet_list"
        | "prompt_library::snippet_get"
        | "prompt_library::snippet_create"
        | "prompt_library::snippet_update"
        | "prompt_library::snippet_delete" => {
            prompt_library::handle(method, invocation, deps).await
        }
        "tree::get_visualization"
        | "tree::get_branches"
        | "tree::get_subtree"
        | "tree::get_ancestors"
        | "tree::compare_branches" => tree::handle(method, invocation, deps).await,
        "repo::list_sessions" | "repo::get_divergence" => {
            repo::handle(method, invocation, deps).await
        }
        "import::list_sources"
        | "import::list_sessions"
        | "import::preview_session"
        | "import::execute" => import::handle(method, invocation, deps).await,
        "git::clone" => git::handle(method, invocation, deps).await,
        "git::sync_main"
        | "git::push"
        | "git::list_local_branches"
        | "git::list_remote_branches"
        | "worktree::finalize_session"
        | "worktree::rebase_on_main"
        | "worktree::start_merge"
        | "worktree::list_conflicts"
        | "worktree::resolve_conflict"
        | "worktree::continue_merge"
        | "worktree::abort_merge"
        | "worktree::resolve_conflicts_with_subagent" => {
            git_workflow::handle(method, invocation, deps).await
        }
        "worktree::get_status"
        | "worktree::is_git_repo"
        | "worktree::commit"
        | "worktree::merge"
        | "worktree::list"
        | "worktree::get_diff"
        | "worktree::acquire"
        | "worktree::release"
        | "worktree::list_session_branches"
        | "worktree::get_committed_diff"
        | "worktree::delete_branch"
        | "worktree::prune_branches"
        | "worktree::stage_files"
        | "worktree::unstage_files"
        | "worktree::discard_files" => worktree::handle(method, invocation, deps).await,
        "browser::start_stream" | "browser::stop_stream" => browser::handle(method).await,
        "display::stop_stream" => display::handle(method, invocation, deps).await,
        "device::register" | "device::unregister" | "device::respond" => {
            device::handle(method, invocation, deps).await
        }
        "transcription::audio" | "transcription::download_model" => {
            transcription::handle(method, invocation, deps).await
        }
        "voice_notes::save" | "voice_notes::delete" => {
            voice_notes::handle(method, invocation, deps).await
        }
        "sandbox::start_container"
        | "sandbox::stop_container"
        | "sandbox::kill_container"
        | "sandbox::remove_container" => sandbox::handle(method, invocation, deps).await,
        "browser::get_status"
        | "voice_notes::list"
        | "transcription::list_models"
        | "sandbox::list_containers" => safe_reads::handle(method, invocation, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("operation {method} is not engine-owned"),
        }),
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
