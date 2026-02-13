//! Model handlers: list, switch.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

fn known_models() -> Vec<Value> {
    vec![
        serde_json::json!({
            "id": "claude-opus-4-6",
            "name": "Claude Opus 4.6",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPer1M": 15.0,
            "outputCostPer1M": 75.0,
        }),
        serde_json::json!({
            "id": "claude-sonnet-4-5-20250929",
            "name": "Claude Sonnet 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPer1M": 3.0,
            "outputCostPer1M": 15.0,
        }),
        serde_json::json!({
            "id": "claude-haiku-4-5-20251001",
            "name": "Claude Haiku 4.5",
            "provider": "anthropic",
            "contextWindow": 200_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPer1M": 0.80,
            "outputCostPer1M": 4.0,
        }),
        serde_json::json!({
            "id": "gpt-4o",
            "name": "GPT-4o",
            "provider": "openai",
            "contextWindow": 128_000,
            "supportsThinking": false,
            "supportsImages": true,
            "inputCostPer1M": 2.50,
            "outputCostPer1M": 10.0,
        }),
        serde_json::json!({
            "id": "gemini-2.0-pro",
            "name": "Gemini 2.0 Pro",
            "provider": "google",
            "contextWindow": 1_000_000,
            "supportsThinking": true,
            "supportsImages": true,
            "inputCostPer1M": 1.25,
            "outputCostPer1M": 10.0,
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
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "models": known_models() }))
    }
}

/// Switch the model for a session.
pub struct SwitchModelHandler;

#[async_trait]
impl MethodHandler for SwitchModelHandler {
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

        ctx.event_store
            .update_latest_model(&session_id, &model)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

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
    async fn list_models_includes_anthropic() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["id"] == "claude-opus-4-6"));
        assert!(models.iter().any(|m| m["id"] == "claude-sonnet-4-5-20250929"));
    }

    #[tokio::test]
    async fn list_models_includes_openai() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["provider"] == "openai"));
    }

    #[tokio::test]
    async fn list_models_includes_google() {
        let ctx = make_test_context();
        let result = ListModelsHandler.handle(None, &ctx).await.unwrap();
        let models = result["models"].as_array().unwrap();
        assert!(models.iter().any(|m| m["provider"] == "google"));
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
            assert!(model["inputCostPer1M"].is_number());
            assert!(model["outputCostPer1M"].is_number());
        }
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
}
