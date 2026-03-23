//! RPC handlers for RenderUI: getStatus, getCanvasUrl.

use async_trait::async_trait;
use serde_json::{Value, json};
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Get the render server status.
pub struct GetStatusHandler;

#[async_trait]
impl MethodHandler for GetStatusHandler {
    #[instrument(skip(self, ctx), fields(method = "renderUI.getStatus"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        match &ctx.render_ui_provider {
            Some(provider) => {
                let status = provider.get_status();
                Ok(serde_json::to_value(status).unwrap_or(json!({"status": "error", "message": "serialization failed"})))
            }
            None => Ok(json!({"status": "stopped"})),
        }
    }
}

/// Get the URL for a canvas by ID.
pub struct GetCanvasUrlHandler;

#[async_trait]
impl MethodHandler for GetCanvasUrlHandler {
    #[instrument(skip(self, ctx), fields(method = "renderUI.getCanvasUrl"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let canvas_id = require_string_param(params.as_ref(), "canvasId")?;
        match &ctx.render_ui_provider {
            Some(provider) => {
                let url = provider.canvas_url(&canvas_id);
                Ok(json!({
                    "canvasId": canvas_id,
                    "url": url,
                    "found": url.is_some(),
                }))
            }
            None => Ok(json!({
                "canvasId": canvas_id,
                "url": null,
                "found": false,
            })),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn get_status_without_provider() {
        let ctx = make_test_context();
        let result = GetStatusHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["status"], "stopped");
    }

    #[tokio::test]
    async fn get_canvas_url_without_provider() {
        let ctx = make_test_context();
        let result = GetCanvasUrlHandler
            .handle(Some(json!({"canvasId": "c1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["found"], false);
        assert!(result["url"].is_null());
    }

    #[tokio::test]
    async fn get_canvas_url_missing_param() {
        let ctx = make_test_context();
        let err = GetCanvasUrlHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
