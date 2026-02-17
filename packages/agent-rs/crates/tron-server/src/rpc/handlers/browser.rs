//! Browser handlers: startStream, stopStream, getStatus.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Start browser streaming for a session.
pub struct StartStreamHandler;

#[async_trait]
impl MethodHandler for StartStreamHandler {
    #[instrument(skip(self, ctx), fields(method = "browser.startStream"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let Some(ref svc) = ctx.browser_service else {
            return Err(RpcError::NotAvailable {
                message: "Browser streaming not available (Chrome not found)".into(),
            });
        };
        svc.start_stream(&session_id).await.map_err(|e| {
            RpcError::Internal {
                message: e.to_string(),
            }
        })?;
        Ok(serde_json::json!({ "success": true }))
    }
}

/// Stop browser streaming.
pub struct StopStreamHandler;

#[async_trait]
impl MethodHandler for StopStreamHandler {
    #[instrument(skip(self, ctx), fields(method = "browser.stopStream"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        if let Some(ref svc) = ctx.browser_service {
            svc.stop_stream(&session_id).await.map_err(|e| {
                RpcError::Internal {
                    message: e.to_string(),
                }
            })?;
        }
        Ok(serde_json::json!({ "success": true }))
    }
}

/// Get browser streaming status.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "browser.getStatus"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let status = ctx
            .browser_service
            .as_ref()
            .map(|svc| svc.get_status(&session_id))
            .unwrap_or_default();
        Ok(serde_json::to_value(status).unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn start_stream_not_available_when_no_service() {
        let ctx = make_test_context();
        let err = StartStreamHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn start_stream_missing_session() {
        let ctx = make_test_context();
        let err = StartStreamHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn stop_stream_no_service_succeeds() {
        let ctx = make_test_context();
        let result = StopStreamHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn get_status_no_service_returns_defaults() {
        let ctx = make_test_context();
        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasBrowser"], false);
        assert_eq!(result["isStreaming"], false);
    }
}
