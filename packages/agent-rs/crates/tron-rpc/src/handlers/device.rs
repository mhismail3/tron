//! Device handlers: register, unregister.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Register an APNS device token.
pub struct RegisterTokenHandler;

#[async_trait]
impl MethodHandler for RegisterTokenHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _token = require_string_param(params.as_ref(), "token")?;
        Ok(serde_json::json!({ "registered": true }))
    }
}

/// Unregister an APNS device token.
pub struct UnregisterTokenHandler;

#[async_trait]
impl MethodHandler for UnregisterTokenHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _token = require_string_param(params.as_ref(), "token")?;
        Ok(serde_json::json!({ "unregistered": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn register_token_success() {
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(Some(json!({"token": "abc123"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["registered"], true);
    }

    #[tokio::test]
    async fn register_token_missing_param() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn unregister_token_success() {
        let ctx = make_test_context();
        let result = UnregisterTokenHandler
            .handle(Some(json!({"token": "abc123"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["unregistered"], true);
    }

    #[tokio::test]
    async fn unregister_token_missing_param() {
        let ctx = make_test_context();
        let err = UnregisterTokenHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
