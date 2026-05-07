use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Instant;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{ActorKind, EngineError, InProcessFunctionHandler, Invocation};
use crate::events::EventStore;
use crate::prompt_library::store;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::codex_app::CodexAppServerManager;
use crate::server::rpc::client_logs::{ClientLogEntry, ClientLogsService};
use crate::server::rpc::context::{RpcContext, run_blocking_task};
use crate::server::rpc::errors::{self, CLIENT_VERSION_UNSUPPORTED, RpcError, to_json_value};
use crate::server::rpc::filesystem_service;
use crate::server::rpc::handlers::{
    map_event_store_error, opt_array, opt_bool, opt_string, opt_u64, require_param,
    require_string_param,
};
use crate::server::rpc::notification_inbox::NotificationInboxService;
use crate::server::rpc::types::RpcEvent;
use crate::server::rpc::validation::validate_string_param;
use crate::server::websocket::broadcast::BroadcastManager;
use crate::skills::registry::SkillRegistry;

use super::rpc_error_to_engine;

mod agent;
mod context;
mod events;
mod filesystem;
mod job;
mod logs;
mod model;
mod notifications;
mod plan;
mod prompt_library;
mod session;
mod settings;
mod skills;
mod system;

#[derive(Clone)]
pub(super) struct RpcEngineDeps {
    rpc_context: Arc<RpcContext>,
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    agent_deps: Option<crate::server::rpc::context::AgentDeps>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
    profile_runtime: Arc<ProfileRuntime>,
    server_start_time: Instant,
    settings_path: PathBuf,
    auth_path: PathBuf,
    mcp_router: Option<Arc<tokio::sync::RwLock<crate::mcp::router::McpRouter>>>,
    broadcast_manager: Option<Arc<BroadcastManager>>,
    codex_app_server: Option<Arc<CodexAppServerManager>>,
    ws_port: Arc<AtomicU16>,
    onboarded_marker_path: PathBuf,
    engine_host: crate::engine::EngineHostHandle,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
}

impl RpcEngineDeps {
    pub(super) fn from_context(ctx: &RpcContext) -> Self {
        Self {
            rpc_context: Arc::new(ctx.clone()),
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
            broadcast_manager: ctx.broadcast_manager.clone(),
            codex_app_server: ctx.codex_app_server.clone(),
            ws_port: Arc::clone(&ctx.ws_port),
            onboarded_marker_path: ctx.onboarded_marker_path.clone(),
            engine_host: ctx.engine_host.clone(),
            process_manager: ctx.process_manager.clone(),
            job_manager: ctx.job_manager.clone(),
            output_buffer_registry: ctx.output_buffer_registry.clone(),
        }
    }
}

pub(super) struct RpcFunctionHandler {
    pub(super) method: &'static str,
    pub(super) deps: RpcEngineDeps,
}

#[async_trait]
impl InProcessFunctionHandler for RpcFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        rpc_function_value(self.method, &invocation, &self.deps)
            .await
            .map_err(rpc_error_to_engine)
    }
}

async fn rpc_function_value(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let allow_rpc_context = matches!(invocation.causal_context.actor_kind, ActorKind::Client);
    match method {
        "system.ping" | "system.getInfo" => {
            system::handle(method, invocation, deps, allow_rpc_context).await
        }
        "settings.get" | "settings.update" | "settings.resetToDefaults" => {
            settings::handle(method, invocation, deps).await
        }
        "model.list" => model::handle(method, invocation, deps, allow_rpc_context).await,
        "skill.list" | "skill.get" | "skill.refresh" | "skill.activate" | "skill.deactivate"
        | "skill.active" => skills::handle(method, invocation, deps).await,
        "agent.status"
        | "agent.abort"
        | "agent.abortTool"
        | "agent.queuePrompt"
        | "agent.dequeuePrompt"
        | "agent.clearQueue"
        | "agent.deliverSubagentResults"
        | "agent.submitConfirmation"
        | "agent.submitAnswers" => agent::handle(method, invocation, deps).await,
        "logs.ingest" | "logs.recent" => logs::handle(method, invocation, deps).await,
        "events.getHistory" | "events.getSince" | "events.append" => {
            events::handle(method, invocation, deps).await
        }
        "events.subscribe" | "events.unsubscribe" => events::handle(method, invocation, deps).await,
        "filesystem.listDir" | "filesystem.getHome" | "file.read" => {
            filesystem::handle(method, invocation, deps).await
        }
        "filesystem.createDir" => filesystem::handle(method, invocation, deps).await,
        "session.list"
        | "session.create"
        | "session.delete"
        | "session.fork"
        | "session.getHead"
        | "session.getState"
        | "session.getHistory"
        | "session.reconstruct"
        | "session.archive"
        | "session.unarchive"
        | "session.archiveOlderThan"
        | "session.export" => session::handle(method, invocation, deps).await,
        "context.getSnapshot"
        | "context.getDetailedSnapshot"
        | "context.getAuditTrace"
        | "context.shouldCompact"
        | "context.previewCompaction"
        | "context.canAcceptTurn"
        | "context.confirmCompaction"
        | "context.clear"
        | "context.compact" => context::handle(method, invocation, deps).await,
        "job.background"
        | "job.cancel"
        | "job.background.apply"
        | "job.cancel.apply"
        | "job.list"
        | "job.subscribe"
        | "job.unsubscribe" => job::handle(method, invocation, deps).await,
        "notifications.list" | "notifications.markRead" | "notifications.markAllRead" => {
            notifications::handle(method, invocation, deps).await
        }
        "plan.enter" | "plan.exit" | "plan.getState" => {
            plan::handle(method, invocation, deps).await
        }
        "promptHistory.list"
        | "promptHistory.delete"
        | "promptHistory.clear"
        | "promptSnippet.list"
        | "promptSnippet.get"
        | "promptSnippet.create"
        | "promptSnippet.update"
        | "promptSnippet.delete" => prompt_library::handle(method, invocation, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("RPC method {method} is not engine-owned"),
        }),
    }
}

fn map_store_err(e: crate::events::EventStoreError) -> RpcError {
    match e {
        crate::events::EventStoreError::InvalidOperation(message) => {
            RpcError::InvalidParams { message }
        }
        crate::events::EventStoreError::Sqlite(err) => RpcError::Internal {
            message: format!("Database error: {err}"),
        },
        crate::events::EventStoreError::Internal(msg) => RpcError::Internal { message: msg },
        other => map_event_store_error(other),
    }
}
