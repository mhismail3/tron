//! Display handlers: `stopStream`.
//!
//! Allows iOS clients to stop an active display stream on demand.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Stop an active display stream by stream ID.
pub struct StopStreamHandler;

#[async_trait]
impl MethodHandler for StopStreamHandler {
    #[instrument(skip(self, ctx), fields(method = "display.stopStream"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let stream_id = require_string_param(params.as_ref(), "streamId")?;

        let cancelled = match ctx.display_stream_registry {
            Some(ref registry) => registry.cancel(&stream_id),
            None => false,
        };

        Ok(serde_json::json!({
            "streamId": stream_id,
            "stopped": cancelled,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::tools::ui::display_stream::ActiveStreamRegistry;
    use serde_json::json;
    use tokio_util::sync::CancellationToken;

    #[tokio::test]
    async fn stop_stream_cancels_registered_stream() {
        let registry = ActiveStreamRegistry::new();
        let token = CancellationToken::new();
        registry.insert("s1", token.clone());

        let mut ctx = make_test_context();
        ctx.display_stream_registry = Some(registry);

        let result = StopStreamHandler
            .handle(Some(json!({"streamId": "s1"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["stopped"], true);
        assert!(token.is_cancelled());
    }

    #[tokio::test]
    async fn stop_stream_nonexistent_returns_false() {
        let registry = ActiveStreamRegistry::new();
        let mut ctx = make_test_context();
        ctx.display_stream_registry = Some(registry);

        let result = StopStreamHandler
            .handle(Some(json!({"streamId": "nope"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["stopped"], false);
    }

    #[tokio::test]
    async fn stop_stream_no_registry_returns_false() {
        let ctx = make_test_context();
        let result = StopStreamHandler
            .handle(Some(json!({"streamId": "s1"})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["stopped"], false);
    }

    #[tokio::test]
    async fn stop_stream_missing_param() {
        let ctx = make_test_context();
        let err = StopStreamHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
