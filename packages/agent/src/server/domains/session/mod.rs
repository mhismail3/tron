//! session domain worker.
//!
//! This module owns canonical function execution for the session namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "session",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::session_handler,
    )
}

pub(crate) mod commands;
pub mod context;
pub(crate) mod queries;
pub(crate) mod reconstruct;

async fn session_resume_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::queries::SessionQueryService::resume(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_create_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let working_directory = require_string_param(params, "workingDirectory")?;
    let model =
        opt_string(params, "model").unwrap_or_else(|| "claude-sonnet-4-20250514".to_owned());
    let title = opt_string(params, "title");
    let source = opt_string(params, "source");
    let profile = opt_string(params, "profile");
    let use_worktree = opt_bool(params, "useWorktree");
    crate::server::domains::session::commands::SessionCommandService::create(
        &server_context_view(deps),
        crate::server::domains::session::commands::CreateSessionRequest {
            working_directory,
            model,
            title,
            source,
            profile,
            use_worktree,
        },
    )
    .await
}

async fn session_list_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let include_archived = opt_bool(params, "includeArchived").unwrap_or(false);
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    crate::server::domains::session::queries::SessionQueryService::list(
        &server_context_view(deps),
        include_archived,
        limit,
    )
    .await
}

async fn session_get_head_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::queries::SessionQueryService::get_head(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_delete_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::commands::SessionCommandService::delete(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_fork_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let from_event_id = opt_string(params, "fromEventId");
    let title = opt_string(params, "title");
    crate::server::domains::session::commands::SessionCommandService::fork(
        &server_context_view(deps),
        session_id,
        from_event_id,
        title,
    )
    .await
}

async fn session_get_state_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::queries::SessionQueryService::get_state(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_get_history_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    let before_id = opt_string(params, "beforeId");
    crate::server::domains::session::queries::SessionQueryService::get_history(
        &server_context_view(deps),
        session_id,
        limit,
        before_id,
    )
    .await
}

async fn session_reconstruct_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let limit = params
        .and_then(|p| p.get("limit"))
        .and_then(Value::as_u64)
        .map(|value| value as i64);
    let before_sequence = params
        .and_then(|p| p.get("beforeSequence"))
        .and_then(Value::as_i64);
    crate::server::domains::session::reconstruct::SessionReconstructService::reconstruct(
        &server_context_view(deps),
        session_id,
        limit,
        before_sequence,
    )
    .await
}

async fn session_archive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::commands::SessionCommandService::archive(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_unarchive_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::commands::SessionCommandService::unarchive(
        &server_context_view(deps),
        session_id,
    )
    .await
}

async fn session_archive_older_than_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let days_raw = params
        .and_then(|p| p.get("days"))
        .and_then(Value::as_u64)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "missing required parameter 'days' (non-negative integer)".into(),
        })?;
    let days = u32::try_from(days_raw).unwrap_or(u32::MAX);
    crate::server::domains::session::commands::SessionCommandService::archive_older_than(
        &server_context_view(deps),
        days,
    )
    .await
}

async fn session_export_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    crate::server::domains::session::queries::SessionQueryService::export(
        &server_context_view(deps),
        session_id,
    )
    .await
}

pub(super) fn server_context_view(deps: &Deps) -> ServerCapabilityContext {
    ServerCapabilityContext {
        orchestrator: Arc::clone(&deps.orchestrator),
        session_manager: Arc::clone(&deps.session_manager),
        event_store: Arc::clone(&deps.event_store),
        engine_host: deps.engine_host.clone(),
        skill_registry: Arc::clone(&deps.skill_registry),
        memory_registry: Arc::new(parking_lot::Mutex::new(
            crate::runtime::memory::MemoryRegistry::new(),
        )),
        settings_path: deps.settings_path.clone(),
        profile_runtime: Arc::clone(&deps.profile_runtime),
        agent_deps: None,
        server_start_time: deps.server_start_time,
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: String::new(),
        cron_scheduler: None,
        codex_app_server: deps.codex_app_server.clone(),
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            crate::server::domains::session::context::ContextArtifactsService::new(),
        ),
        auth_path: deps.auth_path.clone(),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: deps.mcp_router.clone(),
        display_stream_registry: None,
        process_manager: deps.process_manager.clone(),
        job_manager: deps.job_manager.clone(),
        output_buffer_registry: deps.output_buffer_registry.clone(),
        hook_abort_tracker: Arc::new(crate::runtime::hooks::abort_tracker::HookAbortTracker::new()),
        ws_port: Arc::clone(&deps.ws_port),
        onboarded_marker_path: deps.onboarded_marker_path.clone(),
        release_fetcher: None,
        updater_state_path: crate::core::paths::updater_state_path(),
    }
}
