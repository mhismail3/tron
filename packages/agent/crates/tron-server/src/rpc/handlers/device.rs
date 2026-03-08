//! Device handlers: register, unregister.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::{opt_string, require_string_param};
use crate::rpc::registry::MethodHandler;

/// Register an APNS device token.
pub struct RegisterTokenHandler;

#[async_trait]
impl MethodHandler for RegisterTokenHandler {
    #[instrument(skip(self, ctx), fields(method = "device.register"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let device_token = require_string_param(params.as_ref(), "deviceToken")?;

        // Validate token format: APNS device tokens are 32 bytes = 64 hex chars
        if device_token.len() != 64 || !device_token.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "Invalid device token: expected 64 hex chars, got {} chars",
                    device_token.len()
                ),
            });
        }

        let session_id = opt_string(params.as_ref(), "sessionId");
        let workspace_id = opt_string(params.as_ref(), "workspaceId");
        let environment = opt_string(params.as_ref(), "environment");

        let result = ctx
            .event_store
            .register_device_token(
                &device_token,
                session_id.as_deref(),
                workspace_id.as_deref(),
                environment.as_deref().unwrap_or("production"),
            )
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to register device token: {e}"),
            })?;

        Ok(serde_json::json!({
            "id": result.id,
            "created": result.created,
        }))
    }
}

/// Resolve a pending device request (sent by iOS in response to `device.request` event).
pub struct DeviceRespondHandler;

#[async_trait]
impl MethodHandler for DeviceRespondHandler {
    #[instrument(skip(self, ctx), fields(method = "device.respond"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let request_id = require_string_param(params.as_ref(), "requestId")?;
        let result = params
            .as_ref()
            .and_then(|p| p.get("result"))
            .cloned()
            .unwrap_or(Value::Null);

        if let Some(ref broker) = ctx.device_request_broker {
            let resolved = broker.resolve(&request_id, result);
            Ok(serde_json::json!({ "resolved": resolved }))
        } else {
            Err(RpcError::Internal {
                message: "Device request broker not available".into(),
            })
        }
    }
}

/// Unregister an APNS device token.
pub struct UnregisterTokenHandler;

#[async_trait]
impl MethodHandler for UnregisterTokenHandler {
    #[instrument(skip(self, ctx), fields(method = "device.unregister"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let device_token = require_string_param(params.as_ref(), "deviceToken")?;

        let success = ctx
            .event_store
            .unregister_device_token(&device_token)
            .map_err(|e| RpcError::Internal {
                message: format!("Failed to unregister device token: {e}"),
            })?;

        Ok(serde_json::json!({ "success": success }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn register_token_returns_id_and_created() {
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": "a".repeat(64),
                    "environment": "sandbox"
                })),
                &ctx,
            )
            .await
            .unwrap();

        assert!(result["id"].is_string());
        assert!(!result["id"].as_str().unwrap().is_empty());
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn register_token_existing_returns_created_false() {
        let ctx = make_test_context();
        let token = "b".repeat(64);
        let first = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        let second = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();

        assert_eq!(first["id"], second["id"]);
        assert_eq!(first["created"], true);
        assert_eq!(second["created"], false);
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
    async fn register_token_with_optional_params() {
        let ctx = make_test_context();
        // Register without session/workspace (FK constraints prevent fake IDs in test DB)
        let result = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": "c".repeat(64),
                    "environment": "production"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["id"].is_string());
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn register_token_default_environment() {
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "d".repeat(64)})), &ctx)
            .await
            .unwrap();
        // Should succeed with default "production" environment
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn unregister_token_success() {
        let ctx = make_test_context();
        let token = "e".repeat(64);
        // Register first
        let _ = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        // Then unregister
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn unregister_token_not_found() {
        let ctx = make_test_context();
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], false);
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

    #[tokio::test]
    async fn register_response_matches_wire_format() {
        // Wire format: { id: String, created: Bool }
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "f".repeat(64)})), &ctx)
            .await
            .unwrap();

        // Both fields must be present and correct types
        assert!(result.get("id").is_some(), "missing 'id' field");
        assert!(result.get("created").is_some(), "missing 'created' field");
        assert!(result["id"].is_string(), "'id' must be String");
        assert!(result["created"].is_boolean(), "'created' must be Bool");
    }

    #[tokio::test]
    async fn register_rejects_too_long_token() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "a".repeat(160)})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_rejects_too_short_token() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "abc123"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_rejects_non_hex_token() {
        let ctx = make_test_context();
        let token = "g".repeat(64); // 'g' is not hex
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn unregister_response_matches_wire_format() {
        // Wire format: { success: Bool }
        let ctx = make_test_context();
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": "x"})), &ctx)
            .await
            .unwrap();

        assert!(result.get("success").is_some(), "missing 'success' field");
        assert!(result["success"].is_boolean(), "'success' must be Bool");
    }
}
