//! Model provider catalog and session model-configuration helpers.
//!
//! `model.list` and `model.switch` are served by canonical engine functions.
//! The provider catalog helpers in this file remain
//! the source of truth for model support/deprecation/default reasoning checks,
//! and the model switch helper is a plain domain function rather than a
//! transport dispatch branch.
//!
//! Model data is derived from the provider registries (single source of truth).
//! See `anthropic/types.rs`, `openai/types.rs`, `google/types.rs`, `minimax/types.rs`.
//!
use serde_json::Value;

use crate::domains::auth::credentials::OpenAIAuthPath;
use crate::domains::model::Deps;
use crate::domains::model::providers::anthropic::types::{
    all_claude_models_api_json, get_claude_model,
};
use crate::domains::model::providers::google::types::{
    all_gemini_models_api_json, get_gemini_model,
};
use crate::domains::model::providers::kimi::types::all_kimi_models_api_json;
use crate::domains::model::providers::minimax::types::all_minimax_models_api_json;
use crate::domains::model::providers::ollama::discovery::all_ollama_models_api_json_with_availability;
use crate::domains::model::providers::openai::types::{
    all_openai_models_api_json_for_auth_path, get_openai_model,
};
use crate::domains::model::providers::openai::types::{
    get_openai_model_profile, openai_model_available_for_auth_path,
};
use crate::domains::model::routing::models::registry::strip_provider_prefix;
use crate::shared::server::errors::{self, ToolError};
use crate::shared::server::params::require_string_param;

/// All known models, derived from provider registries (single source of truth).
///
/// Ollama models include live availability status from the local Ollama server.
/// Adding a new model? Update the provider's `types.rs` — it appears here automatically.
pub(crate) async fn known_models(
    openai_auth_path: OpenAIAuthPath,
    ollama_base_url: &str,
) -> Vec<Value> {
    let mut models = all_claude_models_api_json();
    models.extend(all_openai_models_api_json_for_auth_path(openai_auth_path));
    models.extend(all_gemini_models_api_json());
    models.extend(all_minimax_models_api_json());
    models.extend(all_kimi_models_api_json());
    models.extend(all_ollama_models_api_json_with_availability(ollama_base_url).await);
    models
        .into_iter()
        .map(super::attachments::decorate_model)
        .collect()
}

pub(crate) fn is_model_supported(model_id: &str) -> bool {
    if model_id.starts_with("ollama/") {
        return model_id.len() > "ollama/".len();
    }
    let bare = strip_provider_prefix(model_id);
    get_claude_model(bare).is_some()
        || get_openai_model(bare).is_some()
        || get_gemini_model(bare).is_some()
        || crate::domains::model::providers::minimax::types::get_minimax_model(bare).is_some()
        || crate::domains::model::providers::kimi::types::get_kimi_model(bare).is_some()
        || crate::domains::model::providers::ollama::types::get_ollama_model(bare).is_some()
}

pub(crate) fn is_model_retired(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    if let Some(m) = get_claude_model(bare) {
        return m.is_retired;
    }
    if let Some(m) = get_openai_model(bare) {
        return m.is_retired;
    }
    if let Some(m) = get_gemini_model(bare) {
        return m.is_retired;
    }
    // MiniMax, Kimi, and Ollama models currently have no deprecation field.
    false
}

/// Validate an explicit model selection at a durable admission boundary.
///
/// This shares the same support, retirement, and OpenAI auth-path policy as a
/// normal session model switch without requiring a session to exist first.
pub(crate) fn validate_explicit_model(
    model_id: &str,
    auth_path: &std::path::Path,
) -> Result<(), String> {
    let model_id = model_id.trim();
    if model_id.is_empty() {
        return Err("model override must be a non-empty string".to_owned());
    }
    if !is_model_supported(model_id) {
        return Err(format!("unknown model '{model_id}'"));
    }
    if is_model_retired(model_id) {
        return Err(format!("model '{model_id}' is retired"));
    }
    let bare = strip_provider_prefix(model_id);
    if get_openai_model(bare).is_some() {
        let active_auth_path =
            crate::domains::auth::credentials::openai::infer_auth_path(auth_path, None)
                .unwrap_or(OpenAIAuthPath::ChatGptCodex);
        if !openai_model_available_for_auth_path(bare, active_auth_path) {
            return Err(format!(
                "OpenAI model '{model_id}' is not available for the active auth path ({})",
                active_auth_path.as_str()
            ));
        }
    }
    Ok(())
}

/// Reject reasoning overrides the resolved model cannot represent exactly.
pub(crate) fn validate_explicit_reasoning_level(
    model_id: &str,
    reasoning_level: &str,
    auth_path: &std::path::Path,
) -> Result<(), String> {
    let level = reasoning_level.trim();
    if level.is_empty() {
        return Err("reasoningLevel override must be a non-empty string".to_owned());
    }
    validate_explicit_model(model_id, auth_path)?;
    let bare = strip_provider_prefix(model_id);
    let supported = if get_openai_model(bare).is_some() {
        let active_auth_path =
            crate::domains::auth::credentials::openai::infer_auth_path(auth_path, None)
                .unwrap_or(OpenAIAuthPath::ChatGptCodex);
        get_openai_model_profile(bare, active_auth_path)
            .is_some_and(|(_, profile)| profile.reasoning_levels.contains(&level))
    } else if let Some(model) = get_claude_model(bare) {
        model
            .reasoning_levels
            .is_some_and(|levels| levels.contains(&level))
    } else if let Some(model) = get_gemini_model(bare) {
        model.supported_thinking_levels.contains(&level)
    } else {
        false
    };
    if !supported {
        return Err(format!(
            "reasoning level '{level}' is not supported by model '{model_id}'"
        ));
    }
    Ok(())
}

pub(crate) fn active_openai_auth_path(deps: &Deps) -> OpenAIAuthPath {
    crate::domains::auth::credentials::openai::infer_auth_path(&deps.auth_path, None)
        .unwrap_or(OpenAIAuthPath::ChatGptCodex)
}

/// Switch the model for a session.
pub(crate) async fn switch_model(params: Option<&Value>, deps: &Deps) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let requested_model = require_string_param(params, "model")?;
    let model = if requested_model.starts_with("ollama/") {
        requested_model.clone()
    } else {
        strip_provider_prefix(&requested_model).to_string()
    };

    if !is_model_supported(&model) {
        return Err(ToolError::InvalidParams {
            message: format!("Unknown model: {requested_model}"),
        });
    }

    if is_model_retired(&model) {
        return Err(ToolError::InvalidParams {
            message: format!("Model '{model}' is retired and cannot be selected"),
        });
    }

    if get_openai_model(&model).is_some() {
        let auth_path = active_openai_auth_path(deps);
        if !openai_model_available_for_auth_path(&model, auth_path) {
            return Err(ToolError::InvalidParams {
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
        .map_err(|e| ToolError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| ToolError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let previous_model = session.latest_model.clone();

    if deps.orchestrator.has_active_run(&session_id) {
        return Err(ToolError::Custom {
            code: "SESSION_BUSY".into(),
            message: "Cannot switch model while session is running".into(),
            details: None,
        });
    }

    let _ = deps
        .event_store
        .update_latest_model(&session_id, &model)
        .map_err(|e| ToolError::Internal {
            message: e.to_string(),
        })?;

    deps.session_manager.invalidate_session(&session_id);

    let is_cached = deps.session_manager.is_cached(&session_id);
    let _ = deps.orchestrator.broadcast().emit(
        crate::shared::protocol::events::TronEvent::SessionUpdated {
            base: crate::shared::protocol::events::BaseEvent::now(&session_id),
            title: session.title.clone(),
            model: Some(model.clone()),
            event_count: Some(session.event_count),
            turn_count: Some(session.turn_count),
            message_count: Some(session.message_count),
            input_tokens: Some(session.total_input_tokens),
            output_tokens: Some(session.total_output_tokens),
            last_turn_input_tokens: Some(session.last_turn_input_tokens),
            cache_read_tokens: Some(session.total_cache_read_tokens),
            cache_creation_tokens: Some(session.total_cache_creation_tokens),
            cost: Some(session.total_cost),
            last_activity: session.last_activity_at.clone(),
            // `isActive` reports session-cache residency.
            is_active: is_cached,
            last_user_prompt: None,
            last_assistant_response: None,
            parent_session_id: session.parent_session_id.clone(),
            activity_lines: None,
            labels: None,
            organization_group: None,
            organization_changed: None,
            is_archived: None,
        },
    );

    Ok(serde_json::json!({
        "previousModel": previous_model,
        "newModel": model,
    }))
}
