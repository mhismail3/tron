//! RPC method handlers organized by domain.

use std::sync::Arc;

use tron_core::ids::{SessionId, WorkspaceId};
use tron_store::sessions::SessionStatus;
use tron_store::Database;
use tron_telemetry::TelemetryGuard;

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
pub async fn dispatch(
    state: &Arc<HandlerState>,
    method: &str,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    match method {
        // Agent (engine-dependent)
        "agent.message" => agent_message(state, params, id).await,
        "agent.abort" => agent_abort(state, params, id),
        "agent.state" => agent_state(state, params, id),

        // Session
        "session.create" => session_create(state, params, id),
        "session.list" => session_list(state, params, id),
        "session.get" => session_get(state, params, id),
        "session.resume" => session_resume(state, params, id),
        "session.fork" => session_fork(state, params, id),
        "session.delete" => session_delete(state, params, id),
        "session.archive" => session_update_status(state, params, id, SessionStatus::Archived),
        "session.unarchive" => session_update_status(state, params, id, SessionStatus::Active),

        // Events
        "events.list" => events_list(state, params, id),
        "events.sync" => events_sync(state, params, id),

        // Context (engine-dependent)
        "context.get" => context_get(state, params, id),
        "context.compact" => context_compact(id),
        "context.preview" => context_preview(id),

        // Memory
        "memory.list" => memory_list(state, params, id),
        "memory.search" => memory_search(state, params, id),
        "memory.add" => memory_add(state, params, id),

        // Skill
        "skill.list" => skill_list(id),
        "skill.refresh" => skill_refresh(id),
        "skill.remove" => skill_remove(params, id),

        // Settings
        "settings.get" => settings_get(id),
        "settings.update" => settings_update(params, id),

        // Model
        "model.list" => model_list(id),
        "model.switch" => model_switch(params, id),

        // Task
        "task.create" => task_create(params, id),
        "task.update" => task_update(params, id),
        "task.list" => task_list(id),
        "task.delete" => task_delete(params, id),

        // Canvas (deferred)
        "canvas.get" => canvas_stub(id, "get"),
        "canvas.save" => canvas_stub(id, "save"),
        "canvas.list" => canvas_stub(id, "list"),

        // Device (deferred)
        "device.register" => device_register(params, id),

        // Telemetry
        "telemetry.logs" => telemetry_logs(state, params, id),
        "telemetry.metrics" => telemetry_metrics(state, params, id),

        // Health (via RPC)
        "health" => health(state, id),

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
            serde_json::json!({
                "status": "idle",
                "isRunning": false,
                "currentTurn": 0,
            }),
        );
    };

    let session_id = match rpc::require_str(params, "session_id") {
        Ok(s) => SessionId::from_raw(s),
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    let agent_state = orchestrator.state(&session_id);
    let status = if agent_state.is_running {
        "running"
    } else {
        "idle"
    };

    RpcResponse::success(
        id,
        serde_json::json!({
            "status": status,
            "isRunning": agent_state.is_running,
            "currentTurn": agent_state.current_turn,
        }),
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
        Ok(session) => match serde_json::to_value(session) {
            Ok(v) => RpcResponse::success(id, v),
            Err(e) => RpcResponse::internal_error(id, format!("serialization failed: {e}")),
        },
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn session_list(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let status = rpc::optional_str(params, "status").and_then(|s| match s {
        "active" => Some(SessionStatus::Active),
        "archived" => Some(SessionStatus::Archived),
        "deleted" => Some(SessionStatus::Deleted),
        _ => None,
    });
    let limit = rpc::optional_i64(params, "limit").unwrap_or(50) as u32;
    let offset = rpc::optional_i64(params, "offset").unwrap_or(0) as u32;

    let repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match repo.list(&state.default_workspace_id, status.as_ref(), limit, offset) {
        Ok(sessions) => {
            let count = sessions.len();
            RpcResponse::success(id, serde_json::json!({
                "sessions": sessions,
                "totalCount": count,
            }))
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
        Ok(session) => match serde_json::to_value(session) {
            Ok(v) => RpcResponse::success(id, v),
            Err(e) => RpcResponse::internal_error(id, format!("serialization failed: {e}")),
        },
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

    // Reconstruct conversation messages from events
    let event_repo = tron_store::events::EventRepo::new(state.db.clone());
    let messages = match event_repo.reconstruct_messages(&session_id) {
        Ok(m) => m,
        Err(e) => return RpcResponse::internal_error(id, e.to_string()),
    };

    let message_count = messages.len();
    RpcResponse::success(id, serde_json::json!({
        "session": session,
        "messageCount": message_count,
        "resumed": true,
    }))
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

    // Get source session
    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    let source = match sess_repo.get(&source_session_id) {
        Ok(s) => s,
        Err(e) => return RpcResponse::internal_error(id, e.to_string()),
    };

    // Create new session with same model/provider/working_dir
    match sess_repo.create(
        &state.default_workspace_id,
        &source.model,
        &source.provider,
        &source.working_directory,
    ) {
        Ok(new_session) => RpcResponse::success(id, serde_json::json!({
            "session": new_session,
            "forked_from": source_session_id.to_string(),
        })),
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
        Ok(events) => {
            let count = events.len();
            RpcResponse::success(id, serde_json::json!({
                "events": events,
                "totalCount": count,
            }))
        }
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
    let after_sequence = rpc::optional_i64(params, "after_sequence").unwrap_or(0);
    let limit = rpc::optional_i64(params, "limit").unwrap_or(1000) as u32;

    let repo = tron_store::events::EventRepo::new(state.db.clone());
    match repo.list_after_sequence(&session_id, after_sequence, limit) {
        Ok(events) => RpcResponse::success(id, serde_json::json!({
            "events": events,
            "hasMore": false,
        })),
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

    // Return session token info as context summary
    let sess_repo = tron_store::sessions::SessionRepo::new(state.db.clone());
    match sess_repo.get(&session_id) {
        Ok(session) => RpcResponse::success(id, serde_json::json!({
            "session_id": session.id,
            "total_input_tokens": session.tokens.total_input_tokens,
            "total_output_tokens": session.tokens.total_output_tokens,
            "total_cache_read_tokens": session.tokens.total_cache_read_tokens,
            "total_cache_creation_tokens": session.tokens.total_cache_creation_tokens,
            "last_turn_input_tokens": session.tokens.last_turn_input_tokens,
            "total_cost_cents": session.tokens.total_cost_cents,
            "turn_count": session.tokens.turn_count,
        })),
        Err(e) => RpcResponse::internal_error(id, e.to_string()),
    }
}

fn context_compact(id: Option<serde_json::Value>) -> RpcResponse {
    // Compaction requires the engine to send messages to the LLM.
    // Will be wired when agent lifecycle is connected.
    RpcResponse::success(id, serde_json::json!({"queued": true}))
}

fn context_preview(id: Option<serde_json::Value>) -> RpcResponse {
    // Preview the context that would be sent on the next turn.
    // Requires engine context manager.
    RpcResponse::success(id, serde_json::json!({"preview": "Context preview requires active session"}))
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
            RpcResponse::success(id, serde_json::json!({
                "memories": entries,
                "totalCount": count,
            }))
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
        Ok(results) => RpcResponse::success(id, serde_json::json!({
            "results": results,
        })),
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
    RpcResponse::success(id, serde_json::json!({
        "skills": [],
        "totalCount": 0,
    }))
}

fn skill_refresh(id: Option<serde_json::Value>) -> RpcResponse {
    // Re-scan skill directories and update registry.
    // Will be wired to engine's SkillRegistry.
    RpcResponse::success(id, serde_json::json!({"refreshed": true}))
}

fn skill_remove(params: &serde_json::Value, id: Option<serde_json::Value>) -> RpcResponse {
    let name = match rpc::require_str(params, "name") {
        Ok(n) => n,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    // Will be wired to engine's SkillRegistry.
    RpcResponse::success(id, serde_json::json!({"removed": name}))
}

// ── Settings handlers ──

fn settings_get(id: Option<serde_json::Value>) -> RpcResponse {
    // Load from ~/.tron/settings-rs.json, return defaults if not found.
    let settings = load_settings();
    RpcResponse::success(id, settings)
}

fn settings_update(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    // Merge incoming params into current settings.
    let mut settings = load_settings();
    if let Some(obj) = params.as_object() {
        if let Some(settings_obj) = settings.as_object_mut() {
            for (key, value) in obj {
                settings_obj.insert(key.clone(), value.clone());
            }
        }
    }

    // Persist to disk
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
    std::path::PathBuf::from(home).join(".tron").join("settings-rs.json")
}

fn load_settings() -> serde_json::Value {
    let path = settings_file_path();
    match std::fs::read_to_string(&path) {
        Ok(contents) => match serde_json::from_str(&contents) {
            Ok(v) => return v,
            Err(e) => tracing::info!(error = %e, "Settings file corrupted, using defaults"),
        },
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => {
            tracing::warn!(error = %e, "Failed to read settings file, using defaults");
        }
        _ => {} // NotFound is expected on first run
    }
    default_settings()
}

fn default_settings() -> serde_json::Value {
    serde_json::json!({
        "model": "claude-sonnet-4-5-20250929",
        "provider": "anthropic",
        "theme": "dark",
    })
}

// ── Model handlers ──

fn model_list(id: Option<serde_json::Value>) -> RpcResponse {
    let models = tron_llm::models::all_models();
    let model_list: Vec<serde_json::Value> = models
        .iter()
        .map(|m| {
            serde_json::json!({
                "name": m.name,
                "context_window": m.context_window,
                "max_output": m.max_output,
                "supports_thinking": m.supports_thinking,
                "supports_adaptive_thinking": m.supports_adaptive_thinking,
            })
        })
        .collect();

    let count = model_list.len();
    RpcResponse::success(
        id,
        serde_json::json!({
            "models": model_list,
            "totalCount": count,
        }),
    )
}

fn model_switch(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let model_name = match rpc::require_str(params, "model") {
        Ok(m) => m,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };

    // Validate model exists
    let models = tron_llm::models::all_models();
    let found = models.iter().any(|m| m.name == model_name);

    if !found {
        return RpcResponse::invalid_params(id, format!("Unknown model: {model_name}"));
    }

    // Update settings file
    let mut settings = load_settings();
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
        return RpcResponse::internal_error(
            id,
            format!("Failed to persist model switch: {e}"),
        );
    }

    RpcResponse::success(id, serde_json::json!({
        "model": model_name,
        "switched": true,
    }))
}

// ── Task handlers ──

fn task_create(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let content = match rpc::require_str(params, "content") {
        Ok(c) => c,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    let status = rpc::optional_str(params, "status").unwrap_or("pending");
    let task_id = uuid::Uuid::now_v7().to_string();

    RpcResponse::success(id, serde_json::json!({
        "id": task_id,
        "content": content,
        "status": status,
    }))
}

fn task_update(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
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
    // Tasks are ephemeral (in-memory per session via TodoWrite tool).
    // This endpoint returns an empty list; the agent manages tasks internally.
    RpcResponse::success(id, serde_json::json!({
        "tasks": [],
        "totalCount": 0,
    }))
}

fn task_delete(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let task_id = match rpc::require_str(params, "id") {
        Ok(t) => t,
        Err(e) => return RpcResponse::invalid_params(id, e),
    };
    RpcResponse::success(id, serde_json::json!({"id": task_id, "deleted": true}))
}

// ── Canvas handlers (deferred) ──

fn canvas_stub(id: Option<serde_json::Value>, operation: &str) -> RpcResponse {
    RpcResponse::success(id, serde_json::json!({
        "operation": operation,
        "message": "Canvas support is deferred to a future phase",
    }))
}

// ── Device handlers (deferred) ──

fn device_register(
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let device_token = rpc::optional_str(params, "device_token").unwrap_or("unknown");
    let platform = rpc::optional_str(params, "platform").unwrap_or("ios");
    RpcResponse::success(id, serde_json::json!({
        "registered": true,
        "device_token": device_token,
        "platform": platform,
    }))
}

// ── Telemetry handlers ──

fn telemetry_logs(
    state: &Arc<HandlerState>,
    params: &serde_json::Value,
    id: Option<serde_json::Value>,
) -> RpcResponse {
    let Some(ref telemetry) = state.telemetry else {
        return RpcResponse::success(id, serde_json::json!({
            "logs": [],
            "totalCount": 0,
            "enabled": false,
        }));
    };

    let Some(log_sink) = telemetry.logs() else {
        return RpcResponse::success(id, serde_json::json!({
            "logs": [],
            "totalCount": 0,
            "enabled": false,
        }));
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
            RpcResponse::success(id, serde_json::json!({
                "logs": logs,
                "totalCount": count,
                "enabled": true,
            }))
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
        return RpcResponse::success(id, serde_json::json!({
            "metrics": [],
            "totalCount": 0,
            "enabled": false,
        }));
    };

    let Some(metrics) = telemetry.metrics() else {
        return RpcResponse::success(id, serde_json::json!({
            "metrics": [],
            "totalCount": 0,
            "enabled": false,
        }));
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
            RpcResponse::success(id, serde_json::json!({
                "metrics": items,
                "totalCount": count,
                "enabled": true,
            }))
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

    #[tokio::test]
    async fn dispatch_unknown_method() {
        let state = setup();
        let resp = dispatch(&state, "foo.bar", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert!(resp.error.is_some());
        assert_eq!(resp.error.as_ref().unwrap().code, rpc::METHOD_NOT_FOUND);
    }

    #[tokio::test]
    async fn session_create_and_list() {
        let state = setup();
        let resp = dispatch(
            &state, "session.create",
            &serde_json::json!({"model": "claude-opus-4-6", "provider": "anthropic"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_none());
        assert!(resp.result.unwrap()["id"].as_str().is_some());

        let resp = dispatch(&state, "session.list", &serde_json::json!({}), Some(serde_json::json!(2))).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["totalCount"], 1);
    }

    #[tokio::test]
    async fn session_get() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "session.get",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["id"].as_str().unwrap(), session_id);
    }

    #[tokio::test]
    async fn session_resume() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "session.resume",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["resumed"], true);
        assert_eq!(result["messageCount"], 0);
    }

    #[tokio::test]
    async fn session_fork() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "session.fork",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["forked_from"], session_id);
        assert!(result["session"]["id"].as_str().is_some());
    }

    #[tokio::test]
    async fn session_delete() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "session.delete",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["deleted"], true);
    }

    #[tokio::test]
    async fn session_archive_and_unarchive() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "session.archive",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert_eq!(resp.result.unwrap()["status"], "archived");

        let resp = dispatch(
            &state, "session.unarchive",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(3)),
        ).await;
        assert_eq!(resp.result.unwrap()["status"], "active");
    }

    #[tokio::test]
    async fn events_list_empty() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "events.list",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["totalCount"], 0);
    }

    #[tokio::test]
    async fn context_get_returns_tokens() {
        let state = setup();
        let resp = dispatch(&state, "session.create", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        let session_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "context.get",
            &serde_json::json!({"session_id": session_id}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["turn_count"], 0);
        assert_eq!(result["total_input_tokens"], 0);
    }

    #[tokio::test]
    async fn memory_add_and_list() {
        let state = setup();

        let resp = dispatch(
            &state, "memory.add",
            &serde_json::json!({"title": "Test Memory", "content": "Use Arc<Mutex>"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_none());

        let resp = dispatch(&state, "memory.list", &serde_json::json!({}), Some(serde_json::json!(2))).await;
        assert_eq!(resp.result.unwrap()["totalCount"], 1);
    }

    #[tokio::test]
    async fn memory_search() {
        let state = setup();
        dispatch(
            &state, "memory.add",
            &serde_json::json!({"title": "Rust Pattern", "content": "Use Arc<Mutex> for shared state"}),
            Some(serde_json::json!(1)),
        ).await;

        let resp = dispatch(
            &state, "memory.search",
            &serde_json::json!({"query": "Mutex"}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
    }

    #[tokio::test]
    async fn model_list_returns_models() {
        let state = setup();
        let resp = dispatch(&state, "model.list", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert!(resp.result.unwrap()["totalCount"].as_u64().unwrap() > 0);
    }

    #[tokio::test]
    async fn model_switch_valid() {
        let state = setup();
        let resp = dispatch(
            &state, "model.switch",
            &serde_json::json!({"model": "claude-opus-4-6"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["switched"], true);
    }

    #[tokio::test]
    async fn model_switch_invalid() {
        let state = setup();
        let resp = dispatch(
            &state, "model.switch",
            &serde_json::json!({"model": "nonexistent-model"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_some());
    }

    #[tokio::test]
    async fn settings_get_returns_defaults() {
        let state = setup();
        let resp = dispatch(&state, "settings.get", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert!(resp.result.unwrap()["model"].as_str().is_some());
    }

    fn setup_with_orchestrator(
        orch: crate::orchestrator::tests::MockOrchestrator,
    ) -> Arc<HandlerState> {
        let db = Database::in_memory().unwrap();
        let ws_repo = WorkspaceRepo::new(db.clone());
        let ws = ws_repo.get_or_create("/test", "test").unwrap();
        Arc::new(
            HandlerState::new(db, ws.id)
                .with_orchestrator(Arc::new(orch)),
        )
    }

    #[tokio::test]
    async fn agent_message_validates_session_id_required() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
        );
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"prompt": "hi"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, rpc::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn agent_message_validates_prompt_required() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
        );
        let resp = dispatch(
            &state,
            "agent.message",
            &serde_json::json!({"session_id": "sess_123"}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, rpc::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn agent_message_returns_acknowledged_and_run_id() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
        );
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
        let state = setup(); // No orchestrator configured
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
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
        );
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
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
        );
        let resp = dispatch(
            &state,
            "agent.abort",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert_eq!(resp.error.unwrap().code, rpc::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn agent_state_returns_idle_when_no_run() {
        let state = setup_with_orchestrator(
            crate::orchestrator::tests::MockOrchestrator::new(),
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
        assert_eq!(result["status"], "idle");
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
        assert_eq!(result["status"], "running");
        assert_eq!(result["isRunning"], true);
        assert_eq!(result["currentTurn"], 3);
    }

    #[tokio::test]
    async fn agent_state_no_orchestrator_returns_idle() {
        let state = setup(); // No orchestrator
        let resp = dispatch(
            &state,
            "agent.state",
            &serde_json::json!({}),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["status"], "idle");
    }

    #[tokio::test]
    async fn task_crud() {
        let state = setup();

        let resp = dispatch(
            &state, "task.create",
            &serde_json::json!({"content": "Fix bug"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_none());
        let task_id = resp.result.unwrap()["id"].as_str().unwrap().to_string();

        let resp = dispatch(
            &state, "task.update",
            &serde_json::json!({"id": task_id, "status": "completed"}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["updated"], true);

        let resp = dispatch(&state, "task.list", &serde_json::json!({}), Some(serde_json::json!(3))).await;
        assert!(resp.error.is_none());

        let resp = dispatch(
            &state, "task.delete",
            &serde_json::json!({"id": task_id}),
            Some(serde_json::json!(4)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["deleted"], true);
    }

    #[tokio::test]
    async fn canvas_stubs_respond() {
        let state = setup();
        for method in &["canvas.get", "canvas.save", "canvas.list"] {
            let resp = dispatch(&state, method, &serde_json::json!({}), Some(serde_json::json!(1))).await;
            assert!(resp.error.is_none());
        }
    }

    #[tokio::test]
    async fn device_register_responds() {
        let state = setup();
        let resp = dispatch(
            &state, "device.register",
            &serde_json::json!({"device_token": "abc123", "platform": "ios"}),
            Some(serde_json::json!(1)),
        ).await;
        assert!(resp.error.is_none());
        assert_eq!(resp.result.unwrap()["registered"], true);
    }

    #[tokio::test]
    async fn skill_refresh_and_remove() {
        let state = setup();

        let resp = dispatch(&state, "skill.refresh", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert!(resp.error.is_none());

        let resp = dispatch(
            &state, "skill.remove",
            &serde_json::json!({"name": "test-skill"}),
            Some(serde_json::json!(2)),
        ).await;
        assert!(resp.error.is_none());
    }

    #[tokio::test]
    async fn health_check() {
        let state = setup();
        let resp = dispatch(&state, "health", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert_eq!(resp.result.unwrap()["status"], "healthy");
    }

    #[tokio::test]
    async fn missing_required_param() {
        let state = setup();
        let resp = dispatch(&state, "session.get", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert_eq!(resp.error.unwrap().code, rpc::INVALID_PARAMS);
    }

    #[tokio::test]
    async fn skill_list_returns_empty() {
        let state = setup();
        let resp = dispatch(&state, "skill.list", &serde_json::json!({}), Some(serde_json::json!(1))).await;
        assert_eq!(resp.result.unwrap()["totalCount"], 0);
    }

    #[tokio::test]
    async fn telemetry_logs_disabled_returns_empty() {
        let state = setup(); // No telemetry configured
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
        let state = setup(); // No telemetry configured
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
            &serde_json::json!({
                "level": "warn",
                "target": "tron_store",
                "limit": 10,
            }),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["enabled"], false); // No telemetry guard in test setup
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn telemetry_metrics_with_filters() {
        let state = setup();
        let resp = dispatch(
            &state,
            "telemetry.metrics",
            &serde_json::json!({
                "name": "llm.request",
                "limit": 5,
            }),
            Some(serde_json::json!(1)),
        )
        .await;
        assert!(resp.error.is_none());
        let result = resp.result.unwrap();
        assert_eq!(result["enabled"], false);
        assert_eq!(result["totalCount"], 0);
    }
}
