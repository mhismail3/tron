//! Canvas handler: get.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::canvas_service;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Get a canvas by ID.
pub struct GetCanvasHandler;

#[async_trait]
impl MethodHandler for GetCanvasHandler {
    #[instrument(skip(self, ctx), fields(method = "canvas.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let canvas_id = require_string_param(params.as_ref(), "canvasId")?;
        ctx.run_blocking("canvas.get", move || {
            Ok(canvas_service::get_canvas(&canvas_id))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
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
