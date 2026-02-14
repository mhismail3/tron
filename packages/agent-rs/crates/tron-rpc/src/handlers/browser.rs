//! Browser handlers: startStream, stopStream, getStatus.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Start browser streaming for a session.
pub struct StartStreamHandler;

#[async_trait]
impl MethodHandler for StartStreamHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.startStream"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Err(RpcError::NotAvailable {
            message: "Browser streaming requires CDP infrastructure not available in Rust server"
                .into(),
        })
    }
}

/// Stop browser streaming.
pub struct StopStreamHandler;

#[async_trait]
impl MethodHandler for StopStreamHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.stopStream"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        // No-op stop is safe
        Ok(serde_json::json!({ "success": true, "error": null }))
    }
}

/// Get browser streaming status.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, _ctx), fields(method = "browser.getStatus"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({
            "hasBrowser": false,
            "isStreaming": false,
            "currentUrl": null,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
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
    async fn start_stream_missing_session() {
        let ctx = make_test_context();
        let err = StartStreamHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn stop_stream_success() {
        let ctx = make_test_context();
        let result = StopStreamHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn get_status_no_browser() {
        let ctx = make_test_context();
        let result = GetStatusHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasBrowser"], false);
        assert_eq!(result["isStreaming"], false);
    }
}
