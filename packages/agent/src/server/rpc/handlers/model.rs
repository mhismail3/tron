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
use crate::llm::ollama::types::all_ollama_models_api_json_with_availability;
use crate::llm::openai::types::{all_openai_models_api_json, get_openai_model};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// All known models, derived from provider registries (single source of truth).
///
/// Ollama models include live availability status from the local Ollama server.
/// Adding a new model? Update the provider's `types.rs` — it appears here automatically.
async fn known_models() -> Vec<Value> {
    let mut models = all_claude_models_api_json();
    models.extend(all_openai_models_api_json());
    models.extend(all_gemini_models_api_json());
    models.extend(all_minimax_models_api_json());
    models.extend(all_kimi_models_api_json());
    models.extend(all_ollama_models_api_json_with_availability(None).await);
    models
}

fn is_model_supported(model_id: &str) -> bool {
    get_claude_model(model_id).is_some()
        || get_openai_model(model_id).is_some()
        || get_gemini_model(model_id).is_some()
        || crate::llm::minimax::types::get_minimax_model(model_id).is_some()
        || crate::llm::kimi::types::get_kimi_model(model_id).is_some()
        || crate::llm::ollama::types::get_ollama_model(model_id).is_some()
}

fn is_model_deprecated(model_id: &str) -> bool {
    if let Some(m) = get_claude_model(model_id) {
        return m.is_deprecated;
    }
    if let Some(m) = get_gemini_model(model_id) {
        return m.is_deprecated;
    }
    // OpenAI and MiniMax models currently have no deprecation field.
    false
}

/// List available models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, _ctx), fields(method = "model.list"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": known_models().await }))
    }
}

/// Switch the model for a session.
pub struct SwitchModelHandler;

#[async_trait]
impl MethodHandler for SwitchModelHandler {
    #[instrument(skip(self, ctx), fields(method = "model.switch"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let model = require_string_param(params.as_ref(), "model")?;

        if !is_model_supported(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Unknown model: {model}"),
            });
        }

        if is_model_deprecated(&model) {
            return Err(RpcError::InvalidParams {
                message: format!("Model '{model}' is deprecated and cannot be selected"),
            });
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
fn default_reasoning_level(model_id: &str) -> Option<String> {
    if let Some(m) = get_claude_model(model_id) {
        return m.default_reasoning_level.map(String::from);
    }
    if let Some(m) = get_openai_model(model_id) {
        return Some(m.default_reasoning_level.to_string());
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
        let state = ctx.event_store.get_state_at_head(&session_id).ok();
        let previous_level = state
            .as_ref()
            .and_then(|s| s.reasoning_level.clone())
            .or_else(|| {
                state
                    .as_ref()
                    .and_then(|s| default_reasoning_level(&s.model))
            });

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
        assert_eq!(anthropic_count, 10);
    }

    #[tokio::test]
    async fn list_models_includes_all_openai() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-pro"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.4-mini"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex-spark"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
        let openai_count = models
            .iter()
            .filter(|m| m["provider"] == "openai-codex")
            .count();
        assert_eq!(openai_count, 8);
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
        assert_eq!(opus["recommended"], true);
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
    async fn switch_model_invalid() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-opus-4-6", "/tmp", None)
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
            .create_session("claude-sonnet-4-6", "/tmp", None)
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
            .create_session("claude-sonnet-4-6", "/tmp", None)
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
    async fn set_reasoning_level_no_duplicate() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-sonnet-4-6", "/tmp", None)
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
            .create_session("claude-sonnet-4-6", "/tmp", None)
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
            .create_session("claude-sonnet-4-6", "/tmp", None)
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
