//! RPC method handlers organized by domain.

use std::sync::Arc;

use tron_core::ids::{SessionId, WorkspaceId};
use tron_store::sessions::SessionStatus;
use tron_store::Database;
use tron_telemetry::TelemetryGuard;

use crate::compat;
use crate::orchestrator::{AgentOrchestrator, PromptParams};
use crate::rpc::{self, RpcResponse};

/// Shared state available to all RPC handlers.
pub struct HandlerState {
    pub db: Database,
    pub default_workspace_id: WorkspaceId,
    pub telemetry: Option<Arc<TelemetryGuard>>,
    pub orchestrator: Option<Arc<dyn AgentOrchestrator>>,
}

impl HandlerState {
    pub fn new(db: Database, default_workspace_id: WorkspaceId) -> Self {
        Self {
            db,
            default_workspace_id,
            telemetry: None,
            orchestrator: None,
        }
    }

    pub fn with_telemetry(
        db: Database,
        default_workspace_id: WorkspaceId,
        telemetry: Arc<TelemetryGuard>,
    ) -> Self {
        Self {
            db,
            default_workspace_id,
            telemetry: Some(telemetry),
            orchestrator: None,
        }
    }

    pub fn with_orchestrator(mut self, orchestrator: Arc<dyn AgentOrchestrator>) -> Self {
        self.orchestrator = Some(orchestrator);
        self
    }
}

/// Dispatch an RPC method to the appropriate handler.
///
/// Normalizes camelCase params to snake_case before routing, so all
/// handlers receive consistent snake_case keys.
pub async fn dispatch(
    state: &Arc<HandlerState>,
    method: &str,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let params = compat::normalize_params(params);

    match method {
        // Agent (engine-dependent)
        "agent.message" | "agent.prompt" => agent_message(state, &params, id).await,
        "agent.abort" => agent_abort(state, &params, id),
        "agent.state" | "agent.getState" => agent_state(state, &params, id),

        // Session
        "session.create" => session_create(state, &params, id),
        "session.list" => session_list(state, &params, id),
        "session.get" => session_get(state, &params, id),
        "session.resume" => session_resume(state, &params, id),
        "session.fork" => session_fork(state, &params, id),
        "session.delete" => session_delete(state, &params, id),
        "session.archive" => session_update_status(state, &params, id, SessionStatus::Archived),
        "session.unarchive" => session_update_status(state, &params, id, SessionStatus::Active),

        // Events
        "events.list" | "events.getHistory" => events_list(state, &params, id),
        "events.sync" | "events.getSince" => events_sync(state, &params, id),

        // Context (engine-dependent)
        "context.get" => context_get(state, &params, id),
        "context.compact" => context_compact(id),
        "context.preview" => context_preview(id),

        // Memory
        "memory.list" => memory_list(state, &params, id),
        "memory.search" => memory_search(state, &params, id),
        "memory.add" => memory_add(state, &params, id),
        "memory.getHandoffs" => stub_empty_object(id),

        // Skill
        "skill.list" => skill_list(id),
        "skill.get" => stub_empty_object(id),
        "skill.refresh" => skill_refresh(id),
        "skill.remove" => skill_remove(&params, id),

        // Settings
        "settings.get" => settings_get(id),
        "settings.update" => settings_update(&params, id),

        // Model
        "model.list" => model_list(id),
        "model.switch" => model_switch(&params, id),

        // Task
        "task.create" => task_create(&params, id),
        "task.update" => task_update(&params, id),
        "task.list" | "tasks.list" => task_list(id),
        "task.delete" => task_delete(&params, id),

        // Canvas (deferred)
        "canvas.get" => canvas_stub(id, "get"),
        "canvas.save" => canvas_stub(id, "save"),
        "canvas.list" => canvas_stub(id, "list"),

        // Device (deferred)
        "device.register" => device_register(&params, id),

        // System
        "system.ping" | "health" => health(state, id),
        "system.getInfo" => system_get_info(id),

        // Telemetry
        "telemetry.logs" | "logs.export" => telemetry_logs(state, &params, id),
        "telemetry.metrics" => telemetry_metrics(state, &params, id),

        // Filesystem
        "filesystem.getHome" => filesystem_get_home(id),
        "filesystem.listDir" => filesystem_list_dir(&params, id),
        "filesystem.createDir" => filesystem_create_dir(&params, id),

        // Areas
        "areas.list" => stub_empty_array(id, "areas"),

        _ => RpcResponse::method_not_found(id, method),
    }
}

// ── Agent handlers (wired to orchestrator) ──

async fn agent_message(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref orchestrator) = state.orchestrator else {
        return RpcResponse::internal_error(id, "Agent orchestrator not configured");
    };

    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let prompt = match rpc::require_str(params, "prompt") {
        Ok(p) => p.to_string(),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    match orchestrator
        .prompt(PromptParams {
            session_id,
            prompt,
            workspace_id: state.default_workspace_id.clone(),
        })
        .await
    {
        Ok(result) => RpcResponse::success(
            id,
            serde_json::json!({
                "acknowledged": true,
                "runId": result.run_id,
            }),
        ),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn agent_abort(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref orchestrator) = state.orchestrator else {
        return RpcResponse::internal_error(id, "Agent orchestrator not configured");
    };

    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let aborted = orchestrator.abort(&session_id);
    RpcResponse::success(id, serde_json::json!({"aborted": aborted}))
}

fn agent_state(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref orchestrator) = state.orchestrator else {
        return RpcResponse::success(
            id,
            compat::agent_state_response(false, 0, 0, "claude-sonnet-4-5-20250929", 0, 0),
        );
    };

    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let astate = orchestrator.state(&session_id);

    // Look up session for model/token info
    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    let (model, input_tokens, output_tokens, message_count) = match sess_repo.get(&session_id) {
        Ok(session) => (
            session.model.clone(),
            session.tokens.total_input_tokens,
            session.tokens.total_output_tokens,
            session.tokens.turn_count as usize,
        ),
        Err(_) => (
            "claude-sonnet-4-5-20250929".to_string(),
            0,
            0,
            0,
        ),
    };

    RpcResponse::success(
        id,
        compat::agent_state_response(
            astate.is_running,
            astate.current_turn,
            message_count,
            &model,
            input_tokens,
            output_tokens,
        ),
    )
}

// ── Session handlers ──

fn session_create(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let model = rpc::optional_str(params, "model").unwrap_or("claude-sonnet-4-5-20250929");
    let provider = rpc::optional_str(params, "provider").unwrap_or("anthropic");
    let working_dir = rpc::optional_str(params, "working_directory").unwrap_or("/tmp");

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.create(&state.default_workspace_id, model, provider, working_dir) {
        Ok(session) => RpcResponse::success(id, compat::session_create_response(&session)),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_list(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let explicit_status = rpc::optional_str(params, "status").and_then(|s| match s {
        "active" => Some(SessionStatus::Active),
        "archived" => Some(SessionStatus::Archived),
        "deleted" => Some(SessionStatus::Deleted),
        _ => None,
    });
    let include_archived = rpc::optional_bool(params, "include_archived").unwrap_or(false);
    let limit = rpc::optional_i64(params, "limit").unwrap_or(50) as u32;
    let offset = rpc::optional_i64(params, "offset").unwrap_or(0) as u32;

    let has_explicit_status = explicit_status.is_some();
    let status = if has_explicit_status {
        explicit_status
    } else if include_archived {
        None
    } else {
        Some(SessionStatus::Active)
    };

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.list(&state.default_workspace_id, status.as_ref(), limit, offset) {
        Ok(mut sessions) => {
            if include_archived && !has_explicit_status {
                sessions.retain(|s| s.status != SessionStatus::Deleted);
            }
            RpcResponse::success(id, compat::session_list_response(&sessions, limit))
        }
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_get(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.get(&session_id) {
        Ok(session) => RpcResponse::success(id, compat::session_to_ios(&session)),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_resume(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    let session = match sess_repo.get(&session_id) {
        Ok(s) => s,
        Err(e) => return RpcResponse::internal_error(id, e.to_string()),
    };

    let event_repo = tron_store::events::EventRepo::new(state.db.clone());
    let messages = match event_repo.reconstruct_messages(&session_id) {
        Ok(m) => m,
        Err(e) => return RpcResponse::internal_error(id, e.to_string()),
    };

    RpcResponse::success(id, compat::session_resume_response(&session, messages.len()))
}

fn session_fork(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let source_session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    let source = match sess_repo.get(&source_session_id) {
        Ok(s) => s,
        Err(e) => return RpcResponse::internal_error(id, e.to_string()),
    };

    match sess_repo.create(
        &state.default_workspace_id,
        &source.model,
        &source.provider,
        &source.working_directory,
    ) {
        Ok(new_session) => RpcResponse::success(
            id,
            compat::session_fork_response(&new_session, source_session_id.as_ref()),
        ),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_delete(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.delete(&session_id) {
        Ok(_) => RpcResponse::success(id, serde_json::json!({"deleted": true})),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_update_status(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
    status: SessionStatus,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let status_str = match &status {
        SessionStatus::Active => "active",
        SessionStatus::Archived => "archived",
        SessionStatus::Deleted => "deleted",
    };

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.update_status(&session_id, status) {
        Ok(_) => RpcResponse::success(id, serde_json::json!({"status": status_str})),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

// ── Events handlers ──

fn events_list(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let limit = rpc::optional_i64(params, "limit").map(|v| v as u32);
    let offset = rpc::optional_i64(params, "offset").map(|v| v as u32);

    let repo = tron_store::events::EventRepo::new(state.db.clone());
    match repo.list(&session_id, limit, offset) {
        Ok(events) => RpcResponse::success(id, compat::events_list_response(&events)),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn events_sync(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let limit = rpc::optional_i64(params, "limit").unwrap_or(1000) as u32;

    let repo = tron_store::events::EventRepo::new(state.db.clone());

    // Support both after_sequence (events.sync) and after_timestamp (events.getSince)
    let result = if let Some(after_ts) = rpc::optional_str(params, "after_timestamp") {
        repo.list_after_timestamp(&session_id, after_ts, limit)
    } else {
        let after_sequence = rpc::optional_i64(params, "after_sequence").unwrap_or(0);
        repo.list_after_sequence(&session_id, after_sequence, limit)
    };

    match result {
        Ok(events) => RpcResponse::success(id, compat::events_list_response(&events)),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

// ── Context handlers ──

fn context_get(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match sess_repo.get(&session_id) {
        Ok(session) => RpcResponse::success(id, compat::context_get_response(&session)),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn context_compact(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(id, serde_json::json!({"queued": true}))
}

fn context_preview(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(
        id,
        serde_json::json!({"preview": "Context preview requires active session"}),
    )
}

// ── Memory handlers ──

fn memory_list(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let limit = rpc::optional_i64(params, "limit").unwrap_or(100) as u32;
    let offset = rpc::optional_i64(params, "offset").unwrap_or(0) as u32;

    let repo = tron_store::memory::MemoryRepo::new(state.db.clone());
    match repo.list_for_workspace(&state.default_workspace_id, limit, offset) {
        Ok(entries) => {
            let count = entries.len();
            RpcResponse::success(
                id,
                serde_json::json!({
                    "memories": entries,
                    "totalCount": count,
                }),
            )
        }
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn memory_search(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let query = match rpc::require_str(params, "query") {
        Ok(q) => q,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let limit = rpc::optional_i64(params, "limit").unwrap_or(10) as u32;

    let repo = tron_store::memory::MemoryRepo::new(state.db.clone());
    match repo.search(&state.default_workspace_id, query, limit) {
        Ok(results) => RpcResponse::success(id, serde_json::json!({"results": results})),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn memory_add(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let title = match rpc::require_str(params, "title") {
        Ok(t) => t.to_string(),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let content = match rpc::require_str(params, "content") {
        Ok(c) => c.to_string(),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let tokens = content.len().div_ceil(4) as i64;

    let repo = tron_store::memory::MemoryRepo::new(state.db.clone());
    match repo.add(
        &state.default_workspace_id,
        None,
        &title,
        &content,
        tokens,
        tron_store::memory::MemorySource::Manual,
    ) {
        Ok(entry) => match serde_json::to_value(entry) {
            Ok(v) => RpcResponse::success(id, v),
            Err(e) => RpcResponse::internal_error(id, format!("serialization failed: {e}")),
        },
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

// ── Skill handlers ──

fn skill_list(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(
        id,
        serde_json::json!({
            "skills": [],
            "totalCount": 0,
        }),
    )
}

fn skill_refresh(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(id, serde_json::json!({"refreshed": true}))
}

fn skill_remove(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let name = match rpc::require_str(params, "name") {
        Ok(n) => n,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    RpcResponse::success(id, serde_json::json!({"removed": name}))
}

// ── Settings handlers ──

fn settings_get(id: Option<serde_json::Value>) -> RpcResponse {
    // Start with full iOS-compatible defaults, merge on-disk overrides
    let mut settings = compat::default_settings_ios();
    let on_disk = load_settings_from_disk();
    if let (Some(base), Some(disk)) = (settings.as_object_mut(), on_disk.as_object()) {
        for (key, value) in disk {
            base.insert(key.clone(), value.clone());
        }
    }
    RpcResponse::success(id, settings)
}

fn settings_update(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let mut settings = load_settings_from_disk();
    if let Some(obj) = params.as_object() {
        if let Some(settings_obj) = settings.as_object_mut() {
            for (key, value) in obj {
                settings_obj.insert(key.clone(), value.clone());
            }
        }
    }

    let settings_path = settings_file_path();
    if let Some(parent) = settings_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return RpcResponse::internal_error(
                id,
                format!("Failed to create settings directory: {e}"),
            );
        }
    }
    match std::fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap_or_default(),
    ) {
        Ok(_) => RpcResponse::success(id, settings),
        Err(e) => RpcResponse::internal_error(id, format!("Failed to save settings: {e}")),
    }
}

fn settings_file_path() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::PathBuf::from(home)
        .join(".tron")
        .join("settings-rs.json")
}

fn load_settings_from_disk() -> serde_json::Value {
    let path = settings_file_path();
    match std::fs::read_to_string(&path) {
        Ok(contents) => match serde_json::from_str(&contents) {
            Ok(v) => return v,
            Err(e) => tracing::info!(error = %e, "Settings file corrupted, using defaults"),
        },
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            tracing::warn!(error = %e, "Failed to read settings file, using defaults");
        }
        _ => {}
    }
    serde_json::json!({})
}

// ── Model handlers ──

fn model_list(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(id, compat::model_list_response())
}

fn model_switch(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    // Accept both "model" and "modelId" (iOS sends modelId)
    let model_name = match rpc::require_str(params, "model")
        .or_else(|_| rpc::require_str(params, "modelId"))
    {
        Ok(m) => m,
        Err(_) => return RpcResponse::invalid_params(id, "Missing required parameter: model"),
    };

    let models = tron_llm::models::all_models();
    let found = models.iter().any(|m| m.name == model_name);

    if !found {
        return RpcResponse::invalid_params(id, format!("Unknown model: {model_name}"));
    }

    let mut settings = load_settings_from_disk();
    let previous_model = settings
        .get("model")
        .and_then(|v| v.as_str())
        .unwrap_or("claude-sonnet-4-5-20250929")
        .to_string();

    if let Some(obj) = settings.as_object_mut() {
        obj.insert("model".to_string(), serde_json::json!(model_name));
    }
    let settings_path = settings_file_path();
    if let Some(parent) = settings_path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return RpcResponse::internal_error(
                id,
                format!("Failed to create settings directory: {e}"),
            );
        }
    }
    if let Err(e) = std::fs::write(
        &settings_path,
        serde_json::to_string_pretty(&settings).unwrap_or_default(),
    ) {
        return RpcResponse::internal_error(id, format!("Failed to persist model switch: {e}"));
    }

    RpcResponse::success(
        id,
        serde_json::json!({
            "previousModel": previous_model,
            "newModel": model_name,
            "switched": true,
        }),
    )
}

// ── Task handlers ──

fn task_create(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let content = match rpc::require_str(params, "content") {
        Ok(c) => c,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let status = rpc::optional_str(params, "status").unwrap_or("pending");
    let task_id = uuid::Uuid::now_v7().to_string();

    RpcResponse::success(
        id,
        serde_json::json!({
            "id": task_id,
            "content": content,
            "status": status,
        }),
    )
}

fn task_update(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let task_id = match rpc::require_str(params, "id") {
        Ok(t) => t,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let status = rpc::optional_str(params, "status");
    let content = rpc::optional_str(params, "content");

    let mut result = serde_json::json!({"id": task_id, "updated": true});
    if let Some(s) = status {
        result["status"] = serde_json::json!(s);
    }
    if let Some(c) = content {
        result["content"] = serde_json::json!(c);
    }

    RpcResponse::success(id, result)
}

fn task_list(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(
        id,
        serde_json::json!({
            "tasks": [],
            "totalCount": 0,
        }),
    )
}

fn task_delete(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let task_id = match rpc::require_str(params, "id") {
        Ok(t) => t,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    RpcResponse::success(id, serde_json::json!({"id": task_id, "deleted": true}))
}

// ── Canvas handlers (deferred) ──

fn canvas_stub(id: Option<serde_json::Value>, operation: &str) -> RpcResponse {
    RpcResponse::success(
        id,
        serde_json::json!({
            "operation": operation,
            "message": "Canvas support is deferred to a future phase",
        }),
    )
}

// ── Device handlers (deferred) ──

fn device_register(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let device_token = rpc::optional_str(params, "device_token").unwrap_or("unknown");
    let platform = rpc::optional_str(params, "platform").unwrap_or("ios");
    RpcResponse::success(
        id,
        serde_json::json!({
            "registered": true,
            "device_token": device_token,
            "platform": platform,
        }),
    )
}

// ── Filesystem handlers ──

fn filesystem_get_home(id: Option<serde_json::Value>) -> RpcResponse {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let suggested = common_workspace_paths(&home);
    RpcResponse::success(
        id,
        serde_json::json!({
            "homePath": home,
            "suggestedPaths": suggested,
        }),
    )
}

fn common_workspace_paths(home: &str) -> Vec<serde_json::Value> {
    let candidates = ["Projects", "Workspace", "Developer", "Code", "src", "repos"];
    let mut paths = Vec::new();
    for name in &candidates {
        let p = std::path::Path::new(home).join(name);
        let exists = p.exists();
        if exists {
            paths.push(serde_json::json!({
                "name": name,
                "path": p.to_string_lossy(),
                "exists": exists,
            }));
        }
    }
    paths
}

fn filesystem_list_dir(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let path = match rpc::optional_str(params, "path") {
        Some(p) => p.to_string(),
        None => std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()),
    };
    let show_hidden = rpc::optional_bool(params, "show_hidden").unwrap_or(false);

    let dir_path = std::path::Path::new(&path);
    let parent = dir_path.parent().map(|p| p.to_string_lossy().to_string());

    let read_dir = match std::fs::read_dir(dir_path) {
        Ok(rd) => rd,
        Err(e) => return RpcResponse::internal_error(id, format!("Cannot read directory: {e}")),
    };

    let mut entries: Vec<serde_json::Value> = Vec::new();
    for entry in read_dir.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let entry_path = entry.path();
        let metadata = entry.metadata().ok();
        let is_dir = metadata.as_ref().map(|m| m.is_dir()).unwrap_or(false);
        let is_symlink = entry_path.is_symlink();
        let size = metadata.as_ref().and_then(|m| if m.is_file() { Some(m.len() as i64) } else { None });

        entries.push(serde_json::json!({
            "name": name,
            "path": entry_path.to_string_lossy(),
            "isDirectory": is_dir,
            "isSymlink": is_symlink,
            "size": size,
        }));
    }

    entries.sort_by(|a, b| {
        let a_dir = a["isDirectory"].as_bool().unwrap_or(false);
        let b_dir = b["isDirectory"].as_bool().unwrap_or(false);
        b_dir.cmp(&a_dir).then_with(|| {
            let a_name = a["name"].as_str().unwrap_or("");
            let b_name = b["name"].as_str().unwrap_or("");
            a_name.to_lowercase().cmp(&b_name.to_lowercase())
        })
    });

    RpcResponse::success(
        id,
        serde_json::json!({
            "path": path,
            "parent": parent,
            "entries": entries,
        }),
    )
}

fn filesystem_create_dir(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let path = match rpc::require_str(params, "path") {
        Ok(p) => p,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    match std::fs::create_dir_all(path) {
        Ok(_) => RpcResponse::success(
            id,
            serde_json::json!({
                "created": true,
                "path": path,
            }),
        ),
        Err(e) => RpcResponse::internal_error(id, format!("Failed to create directory: {e}")),
    }
}

// ── Stub handlers for iOS-expected methods ──

fn stub_empty_object(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(id, serde_json::json!({}))
}

fn stub_empty_array(id: Option<serde_json::Value>, key: &str) -> RpcResponse {
    RpcResponse::success(id, serde_json::json!({ key: [] }))
}

fn system_get_info(id: Option<serde_json::Value>) -> RpcResponse {
    RpcResponse::success(
        id,
        serde_json::json!({
            "version": env!("CARGO_PKG_VERSION"),
            "name": "tron-rs",
        }),
    )
}

// ── Telemetry handlers ──

fn telemetry_logs(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref telemetry) = state.telemetry else {
        return RpcResponse::success(
            id,
            serde_json::json!({
                "logs": [],
                "totalCount": 0,
                "enabled": false,
            }),
        );
    };

    let Some(log_sink) = telemetry.logs() else {
        return RpcResponse::success(
            id,
            serde_json::json!({
                "logs": [],
                "totalCount": 0,
                "enabled": false,
            }),
        );
    };

    let level = rpc::optional_str(params, "level");
    let target = rpc::optional_str(params, "target").map(|s| s.to_string());
    let session_id = rpc::optional_str(params, "session_id").map(|s| s.to_string());
    let since = rpc::optional_str(params, "since").map(|s| s.to_string());
    let limit = rpc::optional_i64(params, "limit").map(|v| v as u32);

    let query = tron_telemetry::LogQuery {
        level: level.and_then(|l| l.parse().ok()),
        target,
        session_id,
        since,
        limit,
    };

    match log_sink.query(&query) {
        Ok(records) => {
            let count = records.len();
            let logs: Vec<serde_json::Value> = records
                .into_iter()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "timestamp": r.timestamp,
                        "level": r.level,
                        "target": r.target,
                        "message": r.message,
                        "fields": r.fields,
                        "session_id": r.session_id,
                        "agent_id": r.agent_id,
                    })
                })
                .collect();
            RpcResponse::success(
                id,
                serde_json::json!({
                    "logs": logs,
                    "totalCount": count,
                    "enabled": true,
                }),
            )
        }
        Err(e) => RpcResponse::internal_error(id, format!("Failed to query logs: {e}")),
    }
}

fn telemetry_metrics(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref telemetry) = state.telemetry else {
        return RpcResponse::success(
            id,
            serde_json::json!({
                "metrics": [],
                "totalCount": 0,
                "enabled": false,
            }),
        );
    };

    let Some(metrics) = telemetry.metrics() else {
        return RpcResponse::success(
            id,
            serde_json::json!({
                "metrics": [],
                "totalCount": 0,
                "enabled": false,
            }),
        );
    };

    let name = rpc::optional_str(params, "name").map(|s| s.to_string());
    let since = rpc::optional_str(params, "since").map(|s| s.to_string());
    let limit = rpc::optional_i64(params, "limit").map(|v| v as u32);

    let query = tron_telemetry::MetricsQuery {
        name,
        since,
        labels: None,
        limit,
    };

    match metrics.query(&query) {
        Ok(snapshots) => {
            let count = snapshots.len();
            let items: Vec<serde_json::Value> = snapshots
                .into_iter()
                .map(|s| {
                    serde_json::json!({
                        "id": s.id,
                        "timestamp": s.timestamp,
                        "name": s.name,
                        "value": s.value,
                        "labels": s.labels,
                        "metric_type": format!("{:?}", s.metric_type),
                    })
                })
                .collect();
            RpcResponse::success(
                id,
                serde_json::json!({
                    "metrics": items,
                    "totalCount": count,
                    "enabled": true,
                }),
            )
        }
        Err(e) => RpcResponse::internal_error(id, format!("Failed to query metrics: {e}")),
    }
}

// ── Health handlers ──

fn health(state: &Arc<HandlerState>, id: Option<serde_json::Value>) -> RpcResponse {
    let db_ok = state
        .db
        .with_conn(|conn| {
            conn.execute_batch("SELECT 1")?;
            Ok(true)
        })
        .unwrap_or(false);

    RpcResponse::success(
        id,
        serde_json::json!({
            "status": if db_ok { "healthy" } else { "degraded" },
            "components": {
                "database": if db_ok { "ok" } else { "error" },
            },
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_store::workspaces::WorkspaceRepo;

    fn setup() -> Arc<HandlerState> {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        Arc::new(HandlerState::new(db, ws.id))
    }

    fn setup_with_orchestrator(
        orch: crate::orchestrator::tests::MockOrchestrator,
    ) -> Arc<HandlerState> {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        Arc::new(
            HandlerState::new(db, ws.id).with_orchestrator(Arc::new(orch)),
        )
    }

    /// Helper: create a session and return its sessionId.
    async fn create_session(state: &Arc<HandlerState>) -> String {
        let resp = dispatch(
            state,
            "session.create",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        resp.result.unwrap()["sessionId"]
            .as_str()
            .unwrap()
            .to_string()
    }

    // ── Dispatch tests ──

    #[tokio::test]
    async fn dispatch_unknown_method() {
        let state = setup();
        let resp = dispatch(
            &state,
            "foo.bar",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_some());
        assert_eq!(resp.error.as_ref().unwrap().code, "METHOD_NOT_FOUND");
    }

    // ── Session tests (iOS wire format) ──

    #[tokio::test]
    async fn session_create_returns_ios_shape() {
        let state = setup();
        let resp = dispatch(
            &state,
            "session.create",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        let result = resp.result.unwrap();
        assert!(result["sessionId"].is_string());
        assert!(result["model"].is_string());
        assert!(result["createdAt"].is_string());
        assert!(result.get("id").is_none()); // NOT raw SessionRow
    }

    #[tokio::test]
    async fn session_list_returns_ios_shape() {
        let state = setup();
        create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        assert!(result["sessions"][0]["sessionId"].is_string());
        assert!(result["sessions"][0]["isActive"].is_boolean());
        assert_eq!(result["totalCount"], 1);
    }

    #[tokio::test]
    async fn session_get_returns_ios_shape() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.get",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["sessionId"].as_str().unwrap(), sid);
        assert!(result["isActive"].is_boolean());
        assert!(result.get("id").is_none());
    }

    #[tokio::test]
    async fn session_resume_returns_ios_shape() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.resume",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["sessionId"].is_string());
        assert_eq!(result["messageCount"], 0);
        assert!(result["model"].is_string());
        assert!(result["lastActivity"].is_string());
    }

    #[tokio::test]
    async fn session_fork_returns_ios_shape() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.fork",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["newSessionId"].is_string());
        assert_eq!(result["forkedFromSessionId"], sid);
    }

    #[tokio::test]
    async fn session_delete() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.delete",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["deleted"], true);
    }

    #[tokio::test]
    async fn session_archive_and_unarchive() {
        let state = setup();
        let sid = create_session(&state).await;

        let resp = dispatch(
            &state,
            "session.archive",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert_eq!(resp.result.unwrap()["status"], "archived");

        let resp = dispatch(
            &state,
            "session.unarchive",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(3)),
        )
        .await;
        assert_eq!(resp.result.unwrap()["status"], "active");
    }

    // ── camelCase params accepted ──

    #[tokio::test]
    async fn camel_case_params_accepted() {
        let state = setup();
        let resp = dispatch(
            &state,
            "session.create",
            &serde_json::json!({"workingDirectory": "/home/user/project", "model": "claude-opus-4-6"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert!(resp.result.unwrap()["sessionId"].is_string());
    }

    // ── Events tests ──

    #[tokio::test]
    async fn events_list_empty() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "events.list",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["events"].is_array());
        assert!(result["hasMore"].is_boolean());
    }

    // ── Context tests ──

    #[tokio::test]
    async fn context_get_returns_ios_shape() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "context.get",
            &serde_json::json!({"session_id": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["sessionId"].is_string());
        assert!(result["totalInputTokens"].is_number());
        assert!(result["turnCount"].is_number());
        assert!(result.get("session_id").is_none());
    }

    // ── Model tests ──

    #[tokio::test]
    async fn model_list_returns_ios_shape() {
        let state = setup();
        let resp = dispatch(
            &state,
            "model.list",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        let result = resp.result.unwrap();
        assert!(result["models"][0]["id"].is_string());
        assert!(result["models"][0]["contextWindow"].is_number());
        assert!(result["models"][0]["provider"].is_string());
    }

    #[tokio::test]
    async fn model_switch_valid() {
        let state = setup();
        let resp = dispatch(
            &state,
            "model.switch",
            &serde_json::json!({"model": "claude-opus-4-6"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["switched"], true);
    }

    #[tokio::test]
    async fn model_switch_invalid() {
        let state = setup();
        let resp = dispatch(
            &state,
            "model.switch",
            &serde_json::json!({"model": "nonexistent-model"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_some());
    }

    // ── Settings tests ──

    #[tokio::test]
    async fn settings_get_returns_full_ios_shape() {
        let state = setup();
        let resp = dispatch(
            &state,
            "settings.get",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        let result = resp.result.unwrap();
        assert!(result["defaultModel"].is_string());
        assert!(result["compaction"].is_object());
        assert!(result["memory"].is_object());
    }

    // ── Memory tests ──

    #[tokio::test]
    async fn memory_add_and_list() {
        let state = setup();
        let resp = dispatch(
            &state,
            "memory.add",
            &serde_json::json!({"title": "Test Memory", "content": "Use Arc<Mutex>"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());

        let resp = dispatch(
            &state,
            "memory.list",
            &serde_json::json!({}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert_eq!(resp.result.unwrap()["totalCount"], 1);
    }

    #[tokio::test]
    async fn memory_search() {
        let state = setup();
        dispatch(
            &state,
            "memory.add",
            &serde_json::json!({"title": "Rust Pattern", "content": "Use Arc<Mutex> for shared state"}),
            Some(serde_json::json!(1)),
        )
        .await;

        let resp = dispatch(
            &state,
            "memory.search",
            &serde_json::json!({"query": "Mutex"}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
    }

    // ── Agent tests ──

    #[tokio::test]
    async fn agent_prompt_alias_works() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.prompt",
            &serde_json::json!({"sessionId": "sess_123", "prompt": "hello"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["acknowledged"], true);
    }

    #[tokio::test]
    async fn agent_get_state_alias_works() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.getState",
            &serde_json::json!({"sessionId": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["isRunning"], false);
    }

    #[tokio::test]
    async fn events_get_history_alias_works() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "events.getHistory",
            &serde_json::json!({"sessionId": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
    }

    #[tokio::test]
    async fn system_ping_alias_works() {
        let state = setup();
        let resp = dispatch(
            &state,
            "system.ping",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
    }

    #[tokio::test]
    async fn agent_message_validates_session_id_required() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"prompt": "hi"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn agent_message_validates_prompt_required() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"session_id": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn agent_message_returns_acknowledged_and_run_id() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"session_id": "sess_123", "prompt": "hello"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["acknowledged"], true);
        assert!(result["runId"].as_str().is_some());
    }

    #[tokio::test]
    async fn agent_message_returns_error_from_orchestrator() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::with_prompt_error("session not found"),
        );
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"session_id": "sess_123", "prompt": "hello"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_some());
    }

    #[tokio::test]
    async fn agent_message_no_orchestrator_returns_error() {
        let state = setup();
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"session_id": "sess_123", "prompt": "hello"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_some());
    }

    #[tokio::test]
    async fn agent_abort_returns_result() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.abort",
            &serde_json::json!({"session_id": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["aborted"], true);
    }

    #[tokio::test]
    async fn agent_abort_requires_session_id() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.abort",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn agent_state_returns_idle_when_no_run() {
        let state =
            setup_with_orchestrator(crate::orchestrator::tests::MockOrchestrator::new());
        let resp = dispatch(
            &state,
            "agent.state",
            &serde_json::json!({"session_id": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["isRunning"], false);
        assert_eq!(result["currentTurn"], 0);
    }

    #[tokio::test]
    async fn agent_state_returns_running_during_active_run() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::with_running_state(3),
        );
        let resp = dispatch(
            &state,
            "agent.state",
            &serde_json::json!({"session_id": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["isRunning"], true);
        assert_eq!(result["currentTurn"], 3);
    }

    #[tokio::test]
    async fn agent_state_no_orchestrator_returns_idle() {
        let state = setup();
        let resp = dispatch(
            &state,
            "agent.state",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["isRunning"], false);
    }

    // ── Stub handler tests ──

    #[tokio::test]
    async fn stub_handlers_return_success() {
        let state = setup();
        for method in &[
            "memory.getHandoffs",
            "skill.get",
            "system.getInfo",
            "areas.list",
            "logs.export",
        ] {
            let resp = dispatch(
                &state,
                method,
                &serde_json::json!({}),
                Some(serde_json::json!(1)),
            )
            .await;
            assert!(resp.error.is_none(), "Method {method} should not error");
        }
    }

    // ── Remaining existing tests ──

    #[tokio::test]
    async fn task_crud() {
        let state = setup();
        let resp = dispatch(
            &state,
            "task.create",
            &serde_json::json!({"content": "Fix bug"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let task_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state,
            "task.update",
            &serde_json::json!({"id": task_id, "status": "completed"}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["updated"], true);

        let resp = dispatch(
            &state,
            "task.list",
            &serde_json::json!({}),
            Some(serde_json::json!(3)),
        )
        .await;
        assert!(resp.error.is_none());

        let resp = dispatch(
            &state,
            "task.delete",
            &serde_json::json!({"id": task_id}),
            Some(serde_json::json!(4)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["deleted"], true);
    }

    #[tokio::test]
    async fn canvas_stubs_respond() {
        let state = setup();
        for method in &["canvas.get", "canvas.save", "canvas.list"] {
            let resp = dispatch(
                &state,
                method,
                &serde_json::json!({}),
                Some(serde_json::json!(1)),
            )
            .await;
            assert!(resp.error.is_none());
        }
    }

    #[tokio::test]
    async fn device_register_responds() {
        let state = setup();
        let resp = dispatch(
            &state,
            "device.register",
            &serde_json::json!({"device_token": "abc123", "platform": "ios"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["registered"], true);
    }

    #[tokio::test]
    async fn skill_refresh_and_remove() {
        let state = setup();
        let resp = dispatch(
            &state,
            "skill.refresh",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());

        let resp = dispatch(
            &state,
            "skill.remove",
            &serde_json::json!({"name": "test-skill"}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
    }

    #[tokio::test]
    async fn health_check() {
        let state = setup();
        let resp = dispatch(
            &state,
            "health",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.result.unwrap()["status"], "healthy");
    }

    #[tokio::test]
    async fn missing_required_param() {
        let state = setup();
        let resp = dispatch(
            &state,
            "session.get",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn skill_list_returns_empty() {
        let state = setup();
        let resp = dispatch(
            &state,
            "skill.list",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.result.unwrap()["totalCount"], 0);
    }

    #[tokio::test]
    async fn telemetry_logs_disabled_returns_empty() {
        let state = setup();
        let resp = dispatch(
            &state,
            "telemetry.logs",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["enabled"], false);
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn telemetry_metrics_disabled_returns_empty() {
        let state = setup();
        let resp = dispatch(
            &state,
            "telemetry.metrics",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["enabled"], false);
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn telemetry_logs_with_filters() {
        let state = setup();
        let resp = dispatch(
            &state,
            "telemetry.logs",
            &serde_json::json!({"level": "warn", "target": "tron_store", "limit": 10}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["enabled"], false);
    }

    #[tokio::test]
    async fn telemetry_metrics_with_filters() {
        let state = setup();
        let resp = dispatch(
            &state,
            "telemetry.metrics",
            &serde_json::json!({"name": "llm.request", "limit": 5}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["enabled"], false);
    }

    #[tokio::test]
    async fn session_list_has_more_field() {
        let state = setup();
        create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        assert_eq!(result["hasMore"], false); // 1 session < default limit 50
    }

    #[tokio::test]
    async fn session_list_defaults_to_active_only() {
        let state = setup();
        create_session(&state).await;
        let sid2 = create_session(&state).await;
        dispatch(
            &state,
            "session.archive",
            &serde_json::json!({"session_id": sid2}),
            Some(serde_json::json!(99)),
        )
        .await;

        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn session_list_include_archived() {
        let state = setup();
        create_session(&state).await;
        let sid2 = create_session(&state).await;
        dispatch(
            &state,
            "session.archive",
            &serde_json::json!({"session_id": sid2}),
            Some(serde_json::json!(99)),
        )
        .await;

        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({"includeArchived": true}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn session_list_include_archived_excludes_deleted() {
        let state = setup();
        create_session(&state).await;
        let sid2 = create_session(&state).await;
        // Soft-delete via update_status (session.delete hard-deletes)
        let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
        repo.update_status(
            &tron_core::ids::SessionId::from_raw(&sid2),
            SessionStatus::Deleted,
        )
        .unwrap();

        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({"includeArchived": true}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        assert_eq!(result["sessions"].as_array().unwrap().len(), 1);
    }

    // ── Filesystem tests ──

    #[tokio::test]
    async fn filesystem_get_home_returns_path() {
        let state = setup();
        let resp = dispatch(
            &state,
            "filesystem.getHome",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["homePath"].is_string());
        assert!(!result["homePath"].as_str().unwrap().is_empty());
        assert!(result["suggestedPaths"].is_array());
    }

    #[tokio::test]
    async fn filesystem_list_dir_returns_entries() {
        let state = setup();
        let resp = dispatch(
            &state,
            "filesystem.listDir",
            &serde_json::json!({"path": "/tmp"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["path"], "/tmp");
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn filesystem_list_dir_hides_dotfiles_by_default() {
        let state = setup();
        let home = std::env::var("HOME").unwrap();
        let resp = dispatch(
            &state,
            "filesystem.listDir",
            &serde_json::json!({"path": home}),
            Some(serde_json::json!(1)),
        )
        .await;
        let result = resp.result.unwrap();
        let entries = result["entries"].as_array().unwrap();
        let has_dotfile = entries.iter().any(|e| {
            e["name"].as_str().unwrap_or("").starts_with('.')
        });
        assert!(!has_dotfile, "Should hide dotfiles by default");
    }

    #[tokio::test]
    async fn filesystem_create_dir_works() {
        let state = setup();
        let dir = format!("/tmp/tron-test-{}", uuid::Uuid::now_v7());
        let resp = dispatch(
            &state,
            "filesystem.createDir",
            &serde_json::json!({"path": dir}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["created"], true);
        std::fs::remove_dir(&dir).ok();
    }

    // ── Model switch response shape ──

    #[tokio::test]
    async fn model_switch_returns_ios_shape() {
        let state = setup();
        let resp = dispatch(
            &state,
            "model.switch",
            &serde_json::json!({"model": "claude-opus-4-6"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["previousModel"].is_string(), "previousModel missing");
        assert_eq!(result["newModel"], "claude-opus-4-6");
    }

    // ── Events aliases ──

    #[tokio::test]
    async fn events_get_since_alias_works() {
        let state = setup();
        let sid = create_session(&state).await;
        let resp = dispatch(
            &state,
            "events.getSince",
            &serde_json::json!({"sessionId": sid}),
            Some(serde_json::json!(2)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert!(result["events"].is_array());
        assert!(result["hasMore"].is_boolean());
    }

    #[tokio::test]
    async fn tasks_list_plural_alias_works() {
        let state = setup();
        let resp = dispatch(
            &state,
            "tasks.list",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
    }

    // ── Session list iOS fields ──

    #[tokio::test]
    async fn session_list_ios_fields_present() {
        let state = setup();
        create_session(&state).await;
        let resp = dispatch(
            &state,
            "session.list",
            &serde_json::json!({}),
            Some(serde_json::json!(2)),
        )
        .await;
        let result = resp.result.unwrap();
        let session = &result["sessions"][0];
        assert!(session["messageCount"].is_number(), "messageCount missing");
        assert!(session["cost"].is_number(), "cost missing");
        assert!(session["lastActivity"].is_string(), "lastActivity missing");
        assert!(session["cacheReadTokens"].is_number(), "cacheReadTokens missing");
        assert!(session["cacheCreationTokens"].is_number(), "cacheCreationTokens missing");
        assert!(session["lastTurnInputTokens"].is_number(), "lastTurnInputTokens missing");
    }
}
