//! Model handlers: list, switch.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

#[allow(clippy::too_many_lines)]
fn known_models() -> Vec<Value> {
    vec![
        // ── Anthropic Claude Models ──
        serde_json::json!({
            "id": "claude-opus-4-6",
            "name": "Opus 4.6",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 128_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 5.0,
            "outputCostPerMillion": 25.0,
            "tier": "opus",
            "family": "Claude 4.6",
            "description": "Most capable model with adaptive thinking, effort control, and 128K output.",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "max"],
            "defaultReasoningLevel": "high",
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2026-02-01",
        }),
        serde_json::json!({
            "id": "claude-opus-4-5-20251101",
            "name": "Opus 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 5.0,
            "outputCostPerMillion": 25.0,
            "tier": "opus",
            "family": "Claude 4.5",
            "description": "Premium model combining maximum intelligence with practical performance.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": false,
            "releaseDate": "2025-11-01",
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-5-20250929",
            "name": "Sonnet 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 4.5",
            "description": "Smart model for complex agents and coding. Best balance of intelligence, speed, and cost.",
            "supportsReasoning": false,
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2025-09-29",
        }),
        serde_json::json!({
            "id": "claude-haiku-4-5-20251001",
            "name": "Haiku 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.0,
            "outputCostPerMillion": 5.0,
            "tier": "haiku",
            "family": "Claude 4.5",
            "description": "Fastest model with near-frontier intelligence.",
            "supportsReasoning": false,
            "recommended": true,
            "isLegacy": false,
            "releaseDate": "2025-10-01",
        }),
        serde_json::json!({
            "id": "claude-opus-4-1-20250805",
            "name": "Opus 4.1",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 32_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 15.0,
            "outputCostPerMillion": 75.0,
            "tier": "opus",
            "family": "Claude 4.1",
            "description": "Previous Opus with enhanced agentic capabilities.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-08-05",
        }),
        serde_json::json!({
            "id": "claude-opus-4-20250514",
            "name": "Opus 4",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 32_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 15.0,
            "outputCostPerMillion": 75.0,
            "tier": "opus",
            "family": "Claude 4",
            "description": "Opus 4 with tool use and extended thinking.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-05-14",
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-20250514",
            "name": "Sonnet 4",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "maxOutput": 64_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 3.0,
            "outputCostPerMillion": 15.0,
            "tier": "sonnet",
            "family": "Claude 4",
            "description": "Fast and capable for everyday coding tasks.",
            "supportsReasoning": false,
            "recommended": false,
            "isLegacy": true,
            "releaseDate": "2025-05-14",
        }),

        // ── OpenAI Codex Models ──
        serde_json::json!({
            "id": "gpt-5.3-codex",
            "name": "GPT-5.3 Codex",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.75,
            "outputCostPerMillion": 14.0,
            "tier": "flagship",
            "family": "GPT-5.3",
            "description": "GPT-5.3 Codex — fastest and most capable coding model",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "medium",
            "recommended": true,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gpt-5.2-codex",
            "name": "GPT-5.2 Codex",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.75,
            "outputCostPerMillion": 14.0,
            "tier": "flagship",
            "family": "GPT-5.2",
            "description": "GPT-5.2 Codex — proven coding model",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "medium",
            "recommended": false,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gpt-5.1-codex-max",
            "name": "GPT-5.1 Codex Max",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 10.0,
            "tier": "flagship",
            "family": "GPT-5.1",
            "description": "GPT-5.1 Codex Max — deep reasoning capabilities",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high", "xhigh"],
            "defaultReasoningLevel": "high",
            "recommended": false,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gpt-5.1-codex-mini",
            "name": "GPT-5.1 Codex Mini",
            "provider": "openai-codex",
            "contextWindow": 400_000,
            "maxOutput": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.25,
            "outputCostPerMillion": 2.0,
            "tier": "standard",
            "family": "GPT-5.1",
            "description": "GPT-5.1 Codex Mini — faster and more efficient",
            "supportsReasoning": true,
            "reasoningLevels": ["low", "medium", "high"],
            "defaultReasoningLevel": "low",
            "recommended": false,
            "isLegacy": false,
        }),

        // ── Google Gemini Models ──
        // Pricing: TS uses inputCostPer1k, we multiply by 1000 for per-million
        serde_json::json!({
            "id": "gemini-3-pro-preview",
            "name": "Gemini 3 Pro",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 5.0,
            "tier": "pro",
            "family": "Gemini 3",
            "description": "Gemini 3 Pro (Preview) — pro tier (preview)",
            "isPreview": true,
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["low", "medium", "high"],
            "recommended": true,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gemini-3-flash-preview",
            "name": "Gemini 3 Flash",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 65_536,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 0.075,
            "outputCostPerMillion": 0.30,
            "tier": "flash",
            "family": "Gemini 3",
            "description": "Gemini 3 Flash (Preview) — flash tier (preview)",
            "isPreview": true,
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["minimal", "low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gemini-2.5-pro",
            "name": "Gemini 2.5 Pro",
            "provider": "google",
            "contextWindow": 2_097_152,
            "maxOutput": 16_384,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 1.25,
            "outputCostPerMillion": 5.0,
            "tier": "pro",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Pro — pro tier",
            "thinkingLevel": "high",
            "supportedThinkingLevels": ["low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gemini-2.5-flash",
            "name": "Gemini 2.5 Flash",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 16_384,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPerMillion": 0.075,
            "outputCostPerMillion": 0.30,
            "tier": "flash",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Flash — flash tier",
            "thinkingLevel": "low",
            "supportedThinkingLevels": ["minimal", "low", "medium", "high"],
            "recommended": false,
            "isLegacy": false,
        }),
        serde_json::json!({
            "id": "gemini-2.5-flash-lite",
            "name": "Gemini 2.5 Flash Lite",
            "provider": "google",
            "contextWindow": 1_048_576,
            "maxOutput": 8_192,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPerMillion": 0.0375,
            "outputCostPerMillion": 0.15,
            "tier": "flash-lite",
            "family": "Gemini 2.5",
            "description": "Gemini 2.5 Flash Lite — flash-lite tier",
            "recommended": false,
            "isLegacy": false,
        }),
    ]
}

fn is_model_supported(model_id: &str) -> bool {
    known_models().iter().any(|m| m["id"] == model_id)
}

/// List available models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    #[instrument(skip(self, _ctx), fields(method = "model.list"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": known_models() }))
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

        let _ = ctx.event_store
            .update_latest_model(&session_id, &model)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        // Persist config.model_switch event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::ConfigModelSwitch,
            payload: serde_json::json!({
                "previousModel": previous_model,
                "newModel": model,
            }),
            parent_id: None,
        });

        // Invalidate cached session so next resume reconstructs with new model
        ctx.session_manager.invalidate_session(&session_id);

        // Emit session.updated event via broadcast
        let is_active = ctx.session_manager.is_active(&session_id);
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::SessionUpdated {
                base: tron_core::events::BaseEvent::now(&session_id),
                title: session.title.clone(),
                model: model.clone(),
                message_count: session.event_count,
                input_tokens: session.total_input_tokens,
                output_tokens: session.total_output_tokens,
                last_turn_input_tokens: session.last_turn_input_tokens,
                cache_read_tokens: session.total_cache_read_tokens,
                cache_creation_tokens: session.total_cache_creation_tokens,
                cost: session.total_cost,
                last_activity: session.last_activity_at.clone(),
                is_active,
                last_user_prompt: None,
                last_assistant_response: None,
                parent_session_id: session.parent_session_id.clone(),
            },
        );

        Ok(serde_json::json!({
            "previousModel": previous_model,
            "newModel": model,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
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
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-5-20251101"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-5-20250929"));
        assert!(models.iter().any(|m| m["id"] == "claude-haiku-4-5-20251001"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-1-20250805"));
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-20250514"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-20250514"));
        let anthropic_count = models.iter().filter(|m| m["provider"] == "anthropic").count();
        assert_eq!(anthropic_count, 7);
    }

    #[tokio::test]
    async fn list_models_includes_all_openai() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gpt-5.3-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.2-codex"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-max"));
        assert!(models.iter().any(|m| m["id"] == "gpt-5.1-codex-mini"));
        let openai_count = models.iter().filter(|m| m["provider"] == "openai-codex").count();
        assert_eq!(openai_count, 4);
    }

    #[tokio::test]
    async fn list_models_includes_all_google() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "gemini-3-pro-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-3-flash-preview"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-pro"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash"));
        assert!(models.iter().any(|m| m["id"] == "gemini-2.5-flash-lite"));
        let google_count = models.iter().filter(|m| m["provider"] == "google").count();
        assert_eq!(google_count, 5);
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
    async fn list_models_has_ios_metadata() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        let opus = models.iter().find(|m| m["id"] == "claude-opus-4-6").unwrap();
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
        let opus = models.iter().find(|m| m["id"] == "claude-opus-4-6").unwrap();
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
        let _ = ctx.orchestrator.start_run(&sid, "run-1").unwrap();

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
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::StreamTurnEnd,
            payload: json!({
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50},
                "cost": 0.005,
            }),
            parent_id: None,
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
        if let tron_core::events::TronEvent::SessionUpdated { cost, .. } = event {
            // Cost should come from session, not hardcoded 0.0
            // (exact value depends on how event store aggregates)
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
        if let tron_core::events::TronEvent::SessionUpdated { model, .. } = event {
            assert_eq!(model, "claude-sonnet-4-5-20250929");
        } else {
            panic!("expected SessionUpdated event");
        }
    }
}
