//! Settings handlers: get, update.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::registry::MethodHandler;

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "stub": true }))
    }
}

/// Update settings.
pub struct UpdateSettingsHandler;

#[async_trait]
impl MethodHandler for UpdateSettingsHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let updates = params.ok_or_else(|| RpcError::InvalidParams {
            message: "Missing settings payload".into(),
        })?;

        Ok(serde_json::json!({
            "updated": true,
            "settings": updates,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_settings_success() {
        let ctx = make_test_context();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn update_settings_success() {
        let ctx = make_test_context();
        let result = UpdateSettingsHandler
            .handle(Some(json!({"theme": "dark"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["updated"], true);
    }

    #[tokio::test]
    async fn update_settings_missing_payload() {
        let ctx = make_test_context();
        let err = UpdateSettingsHandler
            .handle(None, &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_settings_echoes_payload() {
        let ctx = make_test_context();
        let result = UpdateSettingsHandler
            .handle(Some(json!({"model": "opus"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["settings"]["model"], "opus");
    }
}
