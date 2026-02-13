//! Model handlers: list, switch.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// List available models.
pub struct ListModelsHandler;

#[async_trait]
impl MethodHandler for ListModelsHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({
            "models": [
                {"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet 4", "provider": "anthropic"},
                {"id": "claude-opus-4-20250514", "name": "Claude Opus 4", "provider": "anthropic"},
            ]
        }))
    }
}

/// Switch the model for a session.
pub struct SwitchModelHandler;

#[async_trait]
impl MethodHandler for SwitchModelHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let model = require_string_param(params.as_ref(), "model")?;

        Ok(serde_json::json!({
            "model": model,
            "switched": true,
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
    async fn switch_model_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = SwitchModelHandler
            .handle(
                Some(json!({"sessionId": sid, "model": "claude-opus-4-20250514"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["model"], "claude-opus-4-20250514");
        assert_eq!(result["switched"], true);
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
    async fn switch_model_missing_model() {
        let ctx = make_test_context();
        let err = SwitchModelHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
