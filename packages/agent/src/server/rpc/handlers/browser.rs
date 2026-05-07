//! Browser handlers: `startStream`, `stopStream`, `getStatus`.
//!
//! Browser support has been removed. All handlers return `NOT_AVAILABLE`.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::registry::MethodHandler;

/// Start browser streaming for a session.
pub struct StartStreamHandler;

#[async_trait]
impl MethodHandler for StartStreamHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.startStream"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Err(RpcError::NotAvailable {
            message: "Browser streaming has been removed".into(),
        })
    }
}

/// Stop browser streaming.
pub struct StopStreamHandler;

#[async_trait]
impl MethodHandler for StopStreamHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.stopStream"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "success": true }))
    }
}

/// Get browser streaming status.
#[cfg(test)]
pub struct GetStatusHandler;

#[cfg(test)]
#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.getStatus"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({
            "hasBrowser": false,
            "isStreaming": false,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn start_stream_not_available() {
        let ctx = make_test_context();
        let err = StartStreamHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn stop_stream_succeeds() {
        let ctx = make_test_context();
        let result = StopStreamHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn get_status_returns_defaults() {
        let ctx = make_test_context();
        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasBrowser"], false);
        assert_eq!(result["isStreaming"], false);
    }
}
