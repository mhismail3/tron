//! Canvas handler: get.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get a canvas by ID.
pub struct GetCanvasHandler;

#[async_trait]
impl MethodHandler for GetCanvasHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _canvas_id = require_string_param(params.as_ref(), "canvasId")?;
        Ok(serde_json::json!({ "stub": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_canvas_success() {
        let ctx = make_test_context();
        let result = GetCanvasHandler
            .handle(Some(json!({"canvasId": "c1"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
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
