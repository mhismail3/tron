use super::*;

use crate::server::rpc::handlers::model as rpc_model;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    match method {
        "model.list" => model_list_value(&invocation.payload, deps, allow_rpc_context).await,
        "model.switch" => model_switch_value(&invocation.payload, deps).await,
        "config.setReasoningLevel" => set_reasoning_level_value(&invocation.payload, deps).await,
        _ => Err(RpcError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}

async fn model_list_value(
    payload: &Value,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    let auth_json_path = allow_rpc_context
        .then(|| {
            payload
                .pointer("/__rpcContext/authPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.auth_path.clone());
    let auth_path = crate::llm::auth::openai::infer_auth_path(&auth_json_path, None)
        .unwrap_or(crate::llm::openai::types::OpenAIAuthPath::ChatGptCodex);
    Ok(json!({ "models": rpc_model::known_models(auth_path).await }))
}

async fn model_switch_value(payload: &Value, deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let requested_model = require_string_param(Some(payload), "model")?;
    let model = crate::llm::models::registry::strip_provider_prefix(&requested_model).to_string();

    if !rpc_model::is_model_supported(&model) {
        return Err(RpcError::InvalidParams {
            message: format!("Unknown model: {requested_model}"),
        });
    }

    if rpc_model::is_model_deprecated(&model) {
        return Err(RpcError::InvalidParams {
            message: format!("Model '{model}' is deprecated and cannot be selected"),
        });
    }

    if crate::llm::openai::types::get_openai_model(&model).is_some() {
        let auth_path = rpc_model::active_openai_auth_path(&deps.rpc_context);
        if !crate::llm::openai::types::openai_model_available_for_auth_path(&model, auth_path) {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "OpenAI model '{model}' is not available for the active auth path ({})",
                    auth_path.as_str()
                ),
            });
        }
    }

    let session = deps
        .event_store
        .get_session(&session_id)
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;
    let previous_model = session.latest_model.clone();

    if deps.orchestrator.has_active_run(&session_id) {
        return Err(RpcError::Custom {
            code: "SESSION_BUSY".into(),
            message: "Cannot switch model while session is running".into(),
            details: None,
        });
    }

    let _ = deps
        .event_store
        .update_latest_model(&session_id, &model)
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

    let _ = deps.event_store.append(&crate::events::AppendOptions {
        session_id: &session_id,
        event_type: crate::events::EventType::ConfigModelSwitch,
        payload: json!({
            "previousModel": previous_model,
            "newModel": model,
        }),
        parent_id: None,
        sequence: None,
    });

    deps.session_manager.invalidate_session(&session_id);
    let is_active = deps.session_manager.is_active(&session_id);
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::SessionUpdated {
            base: crate::core::events::BaseEvent::now(&session_id),
            title: session.title.clone(),
            model: Some(model.to_owned()),
            message_count: Some(session.event_count),
            input_tokens: Some(session.total_input_tokens),
            output_tokens: Some(session.total_output_tokens),
            last_turn_input_tokens: Some(session.last_turn_input_tokens),
            cache_read_tokens: Some(session.total_cache_read_tokens),
            cache_creation_tokens: Some(session.total_cache_creation_tokens),
            cost: Some(session.total_cost),
            last_activity: session.last_activity_at.clone(),
            is_active,
            last_user_prompt: None,
            last_assistant_response: None,
            parent_session_id: session.parent_session_id.clone(),
            activity_lines: None,
        });

    Ok(json!({
        "previousModel": previous_model,
        "newModel": model,
    }))
}

async fn set_reasoning_level_value(
    payload: &Value,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let new_level = require_string_param(Some(payload), "level")?;

    let _ = deps
        .event_store
        .get_session(&session_id)
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let state = deps
        .event_store
        .get_state_at_head(&session_id)
        .map_err(|e| RpcError::Internal {
            message: format!("failed to resolve session state: {e}"),
        })?;
    let previous_level = state.reasoning_level.clone().or_else(|| {
        rpc_model::default_reasoning_level(
            &state.model,
            rpc_model::active_openai_auth_path(&deps.rpc_context),
        )
    });

    if previous_level.as_deref().map(str::to_lowercase) == Some(new_level.to_lowercase()) {
        return Ok(json!({
            "previousLevel": previous_level,
            "newLevel": new_level,
            "changed": false,
        }));
    }

    let _ = deps.event_store.append(&crate::events::AppendOptions {
        session_id: &session_id,
        event_type: crate::events::EventType::ConfigReasoningLevel,
        payload: json!({
            "previousLevel": previous_level,
            "newLevel": new_level,
        }),
        parent_id: None,
        sequence: None,
    });

    deps.session_manager.invalidate_session(&session_id);
    Ok(json!({
        "previousLevel": previous_level,
        "newLevel": new_level,
        "changed": true,
    }))
}
