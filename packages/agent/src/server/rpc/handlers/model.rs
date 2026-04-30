//! Model handlers: list, switch.
//!
//! Model data is derived from the provider registries (single source of truth).
//! See `anthropic/types.rs`, `openai/types.rs`, `google/types.rs`, `minimax/types.rs`.
//!
//! NOTE: Event appends in this module use `let _ =` because they are supplementary
//! audit-trail emissions. The RPC response has already been determined; a failed
//! append should not change the client-visible result.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::llm::anthropic::types::{all_claude_models_api_json, get_claude_model};
use crate::llm::google::types::{all_gemini_models_api_json, get_gemini_model};
use crate::llm::kimi::types::all_kimi_models_api_json;
use crate::llm::minimax::types::all_minimax_models_api_json;
use crate::llm::models::registry::strip_provider_prefix;
use crate::llm::ollama::types::all_ollama_models_api_json_with_availability;
use crate::llm::openai::types::{
    OpenAIAuthPath, all_openai_models_api_json_for_auth_path, get_openai_model,
    get_openai_model_profile, openai_model_available_for_auth_path,
};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// All known models, derived from provider registries (single source of truth).
///
/// Ollama models include live availability status from the local Ollama server.
/// Adding a new model? Update the provider's `types.rs` — it appears here automatically.
async fn known_models(openai_auth_path: OpenAIAuthPath) -> Vec<Value> {
    let mut models = all_claude_models_api_json();
    models.extend(all_openai_models_api_json_for_auth_path(openai_auth_path));
    models.extend(all_gemini_models_api_json());
    models.extend(all_minimax_models_api_json());
    models.extend(all_kimi_models_api_json());
    models.extend(all_ollama_models_api_json_with_availability(None).await);
    models
}

fn is_model_supported(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    get_claude_model(bare).is_some()
        || get_openai_model(bare).is_some()
        || get_gemini_model(bare).is_some()
        || crate::llm::minimax::types::get_minimax_model(bare).is_some()
        || crate::llm::kimi::types::get_kimi_model(bare).is_some()
        || crate::llm::ollama::types::get_ollama_model(bare).is_some()
}

fn is_model_deprecated(model_id: &str) -> bool {
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

fn active_openai_auth_path(ctx: &RpcContext) -> OpenAIAuthPath {
    crate::llm::auth::openai::infer_auth_path(&ctx.auth_path, None)
        .unwrap_or(OpenAIAuthPath::ChatGptCodex)
}

/// List available models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, ctx), fields(method = "model.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": known_models(active_openai_auth_path(ctx)).await }))
    }
}

/// Switch the model for a session.
pub struct SwitchModelHandler;

#[async_trait]
impl MethodHandler for SwitchModelHandler {
    #[instrument(skip(self, ctx), fields(method = "model.switch"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let requested_model = require_string_param(params.as_ref(), "model")?;
        let model = strip_provider_prefix(&requested_model).to_string();

        if !is_model_supported(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Unknown model: {requested_model}"),
            });
        }

        if is_model_deprecated(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Model '{model}' is deprecated and cannot be selected"),
            });
        }

        if get_openai_model(&model).is_some() {
            let auth_path = active_openai_auth_path(ctx);
            if !openai_model_available_for_auth_path(&model, auth_path) {
                return Err(RpcError::InvalidParams {
                    message: format!(
                        "OpenAI model '{model}' is not available for the active auth path ({})",
                        auth_path.as_str()
                    ),
                });
            }
        }

        // Get current model for response
        let session = ctx
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

        // Reject if session is busy (agent running)
        if ctx.orchestrator.has_active_run(&session_id) {
            return Err(RpcError::Custom {
                code: "SESSION_BUSY".into(),
                message: "Cannot switch model while session is running".into(),
                details: None,
            });
        }

        let _ = ctx
            .event_store
            .update_latest_model(&session_id, &model)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        // Persist config.model_switch event
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::ConfigModelSwitch,
            payload: serde_json::json!({
                "previousModel": previous_model,
                "newModel": model,
            }),
            parent_id: None,
            sequence: None,
        });

        // Invalidate cached session so next resume reconstructs with new model
        ctx.session_manager.invalidate_session(&session_id);

        // Emit session.updated event via broadcast
        let is_active = ctx.session_manager.is_active(&session_id);
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(crate::core::events::TronEvent::SessionUpdated {
                base: crate::core::events::BaseEvent::now(&session_id),
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
}

/// Look up the default reasoning level for a model ID from the provider registries.
fn default_reasoning_level(model_id: &str, openai_auth_path: OpenAIAuthPath) -> Option<String> {
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
pub struct SetReasoningLevelHandler;

#[async_trait]
impl MethodHandler for SetReasoningLevelHandler {
    #[instrument(skip(self, ctx), fields(method = "config.setReasoningLevel"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let new_level = require_string_param(params.as_ref(), "level")?;

        // Verify session exists
        let _ = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Resolve previous level: event history first, then model default.
        // A DB error here is a real failure, not "no prior state" — surface it.
        let state = ctx
            .event_store
            .get_state_at_head(&session_id)
            .map_err(|e| RpcError::Internal {
                message: format!("failed to resolve session state: {e}"),
            })?;
        let previous_level = state
            .reasoning_level
            .clone()
            .or_else(|| default_reasoning_level(&state.model, active_openai_auth_path(ctx)));

        // Skip if level hasn't actually changed (case-insensitive)
        if previous_level.as_deref().map(str::to_lowercase) == Some(new_level.to_lowercase()) {
            return Ok(serde_json::json!({
                "previousLevel": previous_level,
                "newLevel": new_level,
                "changed": false,
            }));
        }

        // Persist config.reasoning_level event
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::ConfigReasoningLevel,
            payload: serde_json::json!({
                "previousLevel": previous_level,
                "newLevel": new_level,
            }),
            parent_id: None,
            sequence: None,
        });

        // Invalidate cached session so next resume reconstructs with new level
        ctx.session_manager.invalidate_session(&session_id);

        Ok(serde_json::json!({
            "previousLevel": previous_level,
            "newLevel": new_level,
            "changed": true,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_models_returns_array() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["models"].is_array());
        assert!(!result["models"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_models_includes_all_anthropic() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-7"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-6"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-6"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-5-20251101"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-sonnet-4-5-20250929")
        );
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-haiku-4-5-20251001")
        );
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-1-20250805"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-20250514"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-20250514"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "claude-3-7-sonnet-20250219")
        );
        assert!(models.iter().any(|m| m["id"] == "claude-3-haiku-20240307"));
        let anthropic_count = models
            .iter()
            .filter(|m| m["provider"] == "anthropic")
            .count();
        assert_eq!(anthropic_count, 11);
    }

    #[tokio::test]
    async fn list_models_includes_all_openai() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gpt-5.5"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-mini"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.2"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
        let openai_count = models
            .iter()
            .filter(|m| m["provider"] == "openai-codex")
            .count();
        assert_eq!(openai_count, 5);
        let gpt55 = models.iter().find(|m| m["id"] == "gpt-5.5").unwrap();
        assert_eq!(gpt55["contextWindow"], 272_000);
        assert_eq!(gpt55["apiEndpoint"], "codex");
        assert_eq!(gpt55["authPaths"], json!(["chatgpt-codex"]));
    }

    #[tokio::test]
    async fn list_models_uses_platform_metadata_for_active_api_key() {
        let mut ctx = make_test_context();
        let dir = tempfile::TempDir::new().unwrap();
        ctx.auth_path = dir.path().join("auth.json");
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path,
            crate::llm::auth::openai::PROVIDER_KEY,
            "test",
            "sk-test",
        )
        .unwrap();

        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let gpt55 = models.iter().find(|m| m["id"] == "gpt-5.5").unwrap();
        assert_eq!(gpt55["contextWindow"], 1_050_000);
        assert_eq!(gpt55["apiEndpoint"], "platform");
        assert_eq!(gpt55["authPaths"], json!(["platform-api-key"]));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-nano"));
        let gpt53 = models.iter().find(|m| m["id"] == "gpt-5.3-codex").unwrap();
        assert_eq!(gpt53["contextWindow"], 400_000);
        assert_eq!(gpt53["apiEndpoint"], "platform");
        assert!(!models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
    }

    #[tokio::test]
    async fn list_models_includes_all_google() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gemini-3.1-pro-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-3-pro-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-3-flash-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-pro"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash"));
        assert!(
            models
                .iter()
                .any(|m| m["id"] == "gemini-3.1-flash-lite-preview")
        );
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash-lite"));
        let google_count = models.iter().filter(|m| m["provider"] == "google").count();
        assert_eq!(google_count, 7);
    }

    #[tokio::test]
    async fn list_models_includes_all_minimax() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.7"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.7-highspeed"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.5"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.5-highspeed"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.1"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2.1-highspeed"));
        assert!(models.iter().any(|m| m["id"] == "MiniMax-M2"));
        let minimax_count = models.iter().filter(|m| m["provider"] == "minimax").count();
        assert_eq!(minimax_count, 7);
    }

    #[tokio::test]
    async fn list_models_minimax_no_images() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models.iter().filter(|m| m["provider"] == "minimax") {
            assert_eq!(
                model["supportsImages"], false,
                "{} should not support images",
                model["id"]
            );
        }
    }

    #[tokio::test]
    async fn list_models_minimax_has_required_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models.iter().filter(|m| m["provider"] == "minimax") {
            assert!(model["id"].is_string());
            assert!(model["name"].is_string());
            assert!(model["provider"].is_string());
            assert!(model["contextWindow"].is_number());
        }
    }

    #[tokio::test]
    async fn list_models_has_required_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model["id"].is_string());
            assert!(model["name"].is_string());
            assert!(model["provider"].is_string());
            assert!(model["contextWindow"].is_number());
            assert!(
                model["sortOrder"].is_number(),
                "Model {} missing sortOrder",
                model["id"]
            );
        }
    }

    #[tokio::test]
    async fn list_models_has_capabilities() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model.get("supportsThinking").is_some());
            assert!(model.get("supportsImages").is_some());
        }
    }

    /// I8: every provider registry must emit the five metadata fields the
    /// iOS wire contract requires (supportsThinking, supportsImages,
    /// supportsDocuments, tier, isLegacy). Missing any of these on the
    /// wire would break `JSONDecoder.decode(ModelInfo.self, …)` after the
    /// iOS side dropped the optional-fallback pattern. This is the
    /// cross-boundary meta-test: new provider registries must satisfy it.
    #[tokio::test]
    async fn list_models_all_models_emit_required_metadata() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(!models.is_empty(), "registry produced no models");
        for model in models {
            let id = model["id"].as_str().unwrap_or("<unknown>");
            assert!(
                model["supportsThinking"].is_boolean(),
                "{id}: supportsThinking must be bool, got {:?}",
                model["supportsThinking"]
            );
            assert!(
                model["supportsImages"].is_boolean(),
                "{id}: supportsImages must be bool, got {:?}",
                model["supportsImages"]
            );
            assert!(
                model["supportsDocuments"].is_boolean(),
                "{id}: supportsDocuments must be bool, got {:?}",
                model["supportsDocuments"]
            );
            assert!(
                model["tier"].is_string(),
                "{id}: tier must be string, got {:?}",
                model["tier"]
            );
            assert!(
                !model["tier"].as_str().unwrap_or("").is_empty(),
                "{id}: tier must be non-empty"
            );
            assert!(
                model["isLegacy"].is_boolean(),
                "{id}: isLegacy must be bool, got {:?}",
                model["isLegacy"]
            );
        }
    }

    #[tokio::test]
    async fn list_models_has_pricing() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(model["inputCostPerMillion"].is_number());
            assert!(model["outputCostPerMillion"].is_number());
        }
    }

    #[tokio::test]
    async fn list_models_has_client_metadata() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let opus = models
            .iter()
            .find(|m| m["id"] == "claude-opus-4-6")
            .unwrap();
        assert_eq!(opus["tier"], "opus");
        assert_eq!(opus["family"], "Claude 4.6");
        assert!(opus["description"].is_string());
        // Opus 4.6 is no longer the recommended Opus — Opus 4.7 supersedes it.
        assert_eq!(opus["recommended"], false);
        assert!(opus["releaseDate"].is_string());
        assert!(opus["maxOutput"].is_number());
        assert_eq!(opus["isLegacy"], false);
    }

    #[tokio::test]
    async fn list_models_anthropic_reasoning_levels() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let opus = models
            .iter()
            .find(|m| m["id"] == "claude-opus-4-6")
            .unwrap();
        assert_eq!(opus["supportsReasoning"], true);
        assert!(opus["reasoningLevels"].is_array());
        assert!(opus["defaultReasoningLevel"].is_string());
    }

    #[tokio::test]
    async fn list_models_google_thinking_levels() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let gemini = models.iter().find(|m| m["id"] == "gemini-2.5-pro").unwrap();
        assert!(gemini["thinkingLevel"].is_string());
        assert!(gemini["supportedThinkingLevels"].is_array());
    }

    #[tokio::test]
    async fn switch_model_valid() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["previousModel"], "claude-opus-4-6");
        assert_eq!(result["newModel"], "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_accepts_openai_prefix_and_persists_bare_model() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "openai/gpt-5.5"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["newModel"], "gpt-5.5");

        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        assert_eq!(session.latest_model, "gpt-5.5");
    }

    #[tokio::test]
    async fn switch_model_rejects_deprecated_openai_alias() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gpt-5.2-codex"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("deprecated"));
    }

    #[tokio::test]
    async fn switch_model_rejects_openai_unavailable_for_api_key_path() {
        let mut ctx = make_test_context();
        let dir = tempfile::TempDir::new().unwrap();
        ctx.auth_path = dir.path().join("auth.json");
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path,
            crate::llm::auth::openai::PROVIDER_KEY,
            "test",
            "sk-test",
        )
        .unwrap();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gpt-5.3-codex-spark"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("platform-api-key"));
    }

    #[tokio::test]
    async fn switch_model_allows_platform_only_openai_when_api_key_active() {
        let mut ctx = make_test_context();
        let dir = tempfile::TempDir::new().unwrap();
        ctx.auth_path = dir.path().join("auth.json");
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path,
            crate::llm::auth::openai::PROVIDER_KEY,
            "test",
            "sk-test",
        )
        .unwrap();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gpt-5.4-pro"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["newModel"], "gpt-5.4-pro");
    }

    #[tokio::test]
    async fn switch_model_invalid() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None, None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "nonexistent-model"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn switch_model_missing_session() {
        let ctx = make_test_context();
        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": "nope", "model": "claude-opus-4-6"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn switch_model_missing_params() {
        let ctx = make_test_context();
        let err = SwitchModelHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn switch_model_persists_change() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
        assert_eq!(session.latest_model, "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_emits_session_updated() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "session_updated");
    }

    #[tokio::test]
    async fn switch_model_persists_config_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.model_switch"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["previousModel"], "claude-opus-4-6");
        assert_eq!(payload["newModel"], "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn switch_model_rejects_busy_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        // Simulate a running session by starting a run via orchestrator
        let _run = ctx.orchestrator.begin_run(&sid, "run-1").unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    #[tokio::test]
    async fn switch_model_invalidates_cache() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        // Resume to cache it
        let _ = ctx.session_manager.resume_session(&sid);
        assert!(ctx.session_manager.is_active(&sid));

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        // After switch, cache should be invalidated
        assert!(!ctx.session_manager.is_active(&sid));
    }

    #[tokio::test]
    async fn switch_model_uses_real_cost() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        // Add a turn end with cost to accumulate session cost
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::StreamTurnEnd,
            payload: json!({
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50},
                "cost": 0.005,
            }),
            parent_id: None,
            sequence: None,
        });

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        if let crate::core::events::TronEvent::SessionUpdated { cost, .. } = event {
            let cost = cost.unwrap_or(0.0);
            assert!(cost >= 0.0);
        } else {
            panic!("expected SessionUpdated event");
        }
    }

    #[tokio::test]
    async fn switch_model_session_updated_has_model() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-sonnet-4-5-20250929"})),
                &ctx,
            )
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        if let crate::core::events::TronEvent::SessionUpdated { model, .. } = event {
            assert_eq!(model, Some("claude-sonnet-4-5-20250929".into()));
        } else {
            panic!("expected SessionUpdated event");
        }
    }

    #[tokio::test]
    async fn switch_model_rejects_deprecated() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gemini-3-pro-preview"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("deprecated"));
    }

    #[tokio::test]
    async fn switch_model_rejects_deprecated_sonnet_37() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let err = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-3-7-sonnet-20250219"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn list_models_deprecated_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();

        // Gemini 3 Pro should be deprecated
        let gemini3 = models
            .iter()
            .find(|m| m["id"] == "gemini-3-pro-preview")
            .unwrap();
        assert_eq!(gemini3["isDeprecated"], true);
        assert_eq!(gemini3["deprecationDate"], "2026-03-09");

        // Gemini 3.1 Pro should NOT be deprecated
        let gemini31 = models
            .iter()
            .find(|m| m["id"] == "gemini-3.1-pro-preview")
            .unwrap();
        assert!(gemini31.get("isDeprecated").is_none() || gemini31["isDeprecated"] == false);

        // Sonnet 3.7 should be deprecated
        let sonnet37 = models
            .iter()
            .find(|m| m["id"] == "claude-3-7-sonnet-20250219")
            .unwrap();
        assert_eq!(sonnet37["isDeprecated"], true);
    }

    #[tokio::test]
    async fn switch_to_gemini_31_succeeds() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None, None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "gemini-3.1-pro-preview"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["newModel"], "gemini-3.1-pro-preview");
    }

    // ── SetReasoningLevelHandler ──

    #[tokio::test]
    async fn set_reasoning_level_emits_event() {
        // Sonnet 4.6 default is "medium" — changing to "max" should emit event
        // with previousLevel resolved from model default
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None, None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["previousLevel"], "medium");
        assert_eq!(result["newLevel"], "max");
        assert_eq!(result["changed"], true);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["previousLevel"], "medium");
        assert_eq!(payload["newLevel"], "max");
    }

    #[tokio::test]
    async fn set_reasoning_level_default_is_noop() {
        // Setting to the model's own default should be a no-op
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None, None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "medium"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 0);
    }

    #[tokio::test]
    async fn set_reasoning_level_uses_codex_openai_default_without_api_key() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("gpt-5.4", "/tmp", None, None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "medium"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["previousLevel"], "xhigh");
        assert_eq!(result["newLevel"], "medium");
        assert_eq!(result["changed"], true);
    }

    #[tokio::test]
    async fn set_reasoning_level_uses_platform_openai_default_with_api_key() {
        let mut ctx = make_test_context();
        let dir = tempfile::TempDir::new().unwrap();
        ctx.auth_path = dir.path().join("auth.json");
        crate::llm::auth::storage::save_named_api_key(
            &ctx.auth_path,
            crate::llm::auth::openai::PROVIDER_KEY,
            "test",
            "sk-test",
        )
        .unwrap();
        let sid = ctx
            .session_manager
            .create_session("gpt-5.4", "/tmp", None, None)
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "medium"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["previousLevel"], "none");
        assert_eq!(result["newLevel"], "medium");
        assert_eq!(result["changed"], true);
    }

    #[tokio::test]
    async fn set_reasoning_level_no_duplicate() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None, None)
            .unwrap();

        let _ = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();

        // Same level again — server resolves previous from event history
        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
    }

    #[tokio::test]
    async fn set_reasoning_level_case_insensitive() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None, None)
            .unwrap();

        let _ = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "Max"})), &ctx)
            .await
            .unwrap();

        let result = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["changed"], false);
    }

    #[tokio::test]
    async fn set_reasoning_level_change_emits_both() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None, None)
            .unwrap();

        // First change: medium (default) → high
        let r1 = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "high"})), &ctx)
            .await
            .unwrap();
        assert_eq!(r1["previousLevel"], "medium");

        // Second change: high (from event) → max
        let r2 = SetReasoningLevelHandler
            .handle(Some(json!({"sessionId": sid, "level": "max"})), &ctx)
            .await
            .unwrap();
        assert_eq!(r2["previousLevel"], "high");
        assert_eq!(r2["newLevel"], "max");
        assert_eq!(r2["changed"], true);

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["config.reasoning_level"], None)
            .unwrap();
        assert_eq!(events.len(), 2);
    }

    #[tokio::test]
    async fn set_reasoning_level_session_not_found() {
        let ctx = make_test_context();
        let err = SetReasoningLevelHandler
            .handle(
                Some(json!({"sessionId": "nonexistent", "level": "high"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert!(matches!(err, RpcError::NotFound { .. }));
    }

    #[tokio::test]
    async fn list_models_has_provider_display_fields() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        for model in models {
            assert!(
                model["providerDisplayName"].is_string(),
                "Model {} missing providerDisplayName",
                model["id"]
            );
            assert!(
                model["providerSortOrder"].is_number(),
                "Model {} missing providerSortOrder",
                model["id"]
            );
        }
    }
}
