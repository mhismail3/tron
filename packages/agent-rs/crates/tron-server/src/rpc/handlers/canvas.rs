//! Canvas handler: get.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Get a canvas by ID.
pub struct GetCanvasHandler;

#[async_trait]
impl MethodHandler for GetCanvasHandler {
    #[instrument(skip(self, _ctx), fields(method = "canvas.get"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let canvas_id = require_string_param(params.as_ref(), "canvasId")?;

        // Check ~/.tron/artifacts/canvases/ for the canvas file
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
        let canvas_path = format!("{home}/.tron/artifacts/canvases/{canvas_id}.json");

        if let Ok(content) = std::fs::read_to_string(&canvas_path) {
            if let Ok(canvas) = serde_json::from_str::<Value>(&content) {
                return Ok(serde_json::json!({
                    "found": true,
                    "canvas": canvas,
                }));
            }
        }

        Ok(serde_json::json!({
            "found": false,
            "canvas": null,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_canvas_not_found() {
        let ctx = make_test_context();
        let result = GetCanvasHandler
            .handle(Some(json!({"canvasId": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["found"], false);
        assert!(result["canvas"].is_null());
    }

    #[tokio::test]
    async fn get_canvas_missing_id() {
        let ctx = make_test_context();
        let err = GetCanvasHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
