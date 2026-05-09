//! Model provider catalog and session model-configuration helpers.
//!
//! `model.list`, `model.switch`, and `config.setReasoningLevel` are served by
//! canonical engine functions. The provider catalog helpers in this file remain
//! the source of truth for model support/deprecation/default reasoning checks,
//! and the mutating helpers are plain domain functions rather than transport
//! dispatch branches.
//!
//! Model data is derived from the provider registries (single source of truth).
//! See `anthropic/types.rs`, `openai/types.rs`, `google/types.rs`, `minimax/types.rs`.
//!
//! NOTE: Event appends in this module use `let _ =` because they are supplementary
//! audit-trail emissions. The capability response has already been determined; a failed
//! append should not change the capability result.

use serde_json::Value;

use super::Deps;
use crate::domains::model::providers::anthropic::types::{
    all_claude_models_api_json, get_claude_model,
};
use crate::domains::model::providers::google::types::{
    all_gemini_models_api_json, get_gemini_model,
};
use crate::domains::model::providers::kimi::types::all_kimi_models_api_json;
use crate::domains::model::providers::minimax::types::all_minimax_models_api_json;
use crate::domains::model::providers::models::registry::strip_provider_prefix;
use crate::domains::model::providers::ollama::types::all_ollama_models_api_json_with_availability;
use crate::domains::model::providers::openai::types::openai_model_available_for_auth_path;
use crate::domains::model::providers::openai::types::{
    OpenAIAuthPath, all_openai_models_api_json_for_auth_path, get_openai_model,
    get_openai_model_profile,
};
use crate::shared::server::errors::{self, CapabilityError};
use crate::shared::server::params::require_string_param;

/// All known models, derived from provider registries (single source of truth).
///
/// Ollama models include live availability status from the local Ollama server.
/// Adding a new model? Update the provider's `types.rs` — it appears here automatically.
pub(crate) async fn known_models(openai_auth_path: OpenAIAuthPath) -> Vec<Value> {
    let mut models = all_claude_models_api_json();
    models.extend(all_openai_models_api_json_for_auth_path(openai_auth_path));
    models.extend(all_gemini_models_api_json());
    models.extend(all_minimax_models_api_json());
    models.extend(all_kimi_models_api_json());
    models.extend(all_ollama_models_api_json_with_availability(None).await);
    models
}

pub(crate) fn is_model_supported(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    get_claude_model(bare).is_some()
        || get_openai_model(bare).is_some()
        || get_gemini_model(bare).is_some()
        || crate::domains::model::providers::minimax::types::get_minimax_model(bare).is_some()
        || crate::domains::model::providers::kimi::types::get_kimi_model(bare).is_some()
        || crate::domains::model::providers::ollama::types::get_ollama_model(bare).is_some()
}

pub(crate) fn is_model_deprecated(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    if let Some(m) = get_claude_model(bare) {
        return m.is_deprecated;
    }
    if let Some(m) = get_openai_model(bare) {
        return m.is_deprecated;
    }
    if let Some(m) = get_gemini_model(bare) {
        return m.is_deprecated;
    }
    // MiniMax, Kimi, and Ollama models currently have no deprecation field.
    false
}

pub(crate) fn active_openai_auth_path(deps: &Deps) -> OpenAIAuthPath {
    crate::domains::auth::provider_credentials::openai::infer_auth_path(&deps.auth_path, None)
        .unwrap_or(OpenAIAuthPath::ChatGptCodex)
}

/// Switch the model for a session.
pub(crate) async fn switch_model(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let requested_model = require_string_param(params, "model")?;
    let model = strip_provider_prefix(&requested_model).to_string();

    if !is_model_supported(&model) {
        return Err(CapabilityError::InvalidParams {
            message: format!("Unknown model: {requested_model}"),
        });
    }

    if is_model_deprecated(&model) {
        return Err(CapabilityError::InvalidParams {
            message: format!("Model '{model}' is deprecated and cannot be selected"),
        });
    }

    if get_openai_model(&model).is_some() {
        let auth_path = active_openai_auth_path(deps);
        if !openai_model_available_for_auth_path(&model, auth_path) {
            return Err(CapabilityError::InvalidParams {
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
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let previous_model = session.latest_model.clone();

    if deps.orchestrator.has_active_run(&session_id) {
        return Err(CapabilityError::Custom {
            code: "SESSION_BUSY".into(),
            message: "Cannot switch model while session is running".into(),
            details: None,
        });
    }

    let _ = deps
        .event_store
        .update_latest_model(&session_id, &model)
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?;

    let _ = deps
        .event_store
        .append(&crate::domains::session::event_store::AppendOptions {
            session_id: &session_id,
            event_type: crate::domains::session::event_store::EventType::ConfigModelSwitch,
            payload: serde_json::json!({
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
        .emit(crate::shared::events::TronEvent::SessionUpdated {
            base: crate::shared::events::BaseEvent::now(&session_id),
            title: session.title.clone(),
            model: Some(model.clone()),
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

    Ok(serde_json::json!({
        "previousModel": previous_model,
        "newModel": model,
    }))
}

/// Look up the default reasoning level for a model ID from the provider registries.
pub(crate) fn default_reasoning_level(
    model_id: &str,
    openai_auth_path: OpenAIAuthPath,
) -> Option<String> {
    let bare = strip_provider_prefix(model_id);
    if let Some(m) = get_claude_model(bare) {
        return m.default_reasoning_level.map(String::from);
    }
    if let Some((_, profile)) = get_openai_model_profile(bare, openai_auth_path) {
        return Some(profile.default_reasoning_level.to_string());
    }
    None
}

/// Set the reasoning level for a session.
///
/// Persists a `config.reasoning_level` event and invalidates the session cache.
/// The server is the source of truth: it resolves `previousLevel` from event
/// history, falling back to the model's `defaultReasoningLevel` for the first
/// change in a session. The client only sends `sessionId` and `level`.
pub(crate) async fn set_reasoning_level(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let new_level = require_string_param(params, "level")?;

    let _ = deps
        .event_store
        .get_session(&session_id)
        .map_err(|e| CapabilityError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let state = deps
        .event_store
        .get_state_at_head(&session_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("failed to resolve session state: {e}"),
        })?;
    let previous_level = state
        .reasoning_level
        .clone()
        .or_else(|| default_reasoning_level(&state.model, active_openai_auth_path(deps)));

    if previous_level.as_deref().map(str::to_lowercase) == Some(new_level.to_lowercase()) {
        return Ok(serde_json::json!({
            "previousLevel": previous_level,
            "newLevel": new_level,
            "changed": false,
        }));
    }

    let _ = deps
        .event_store
        .append(&crate::domains::session::event_store::AppendOptions {
            session_id: &session_id,
            event_type: crate::domains::session::event_store::EventType::ConfigReasoningLevel,
            payload: serde_json::json!({
                "previousLevel": previous_level,
                "newLevel": new_level,
            }),
            parent_id: None,
            sequence: None,
        });

    deps.session_manager.invalidate_session(&session_id);

    Ok(serde_json::json!({
        "previousLevel": previous_level,
        "newLevel": new_level,
        "changed": true,
    }))
}
