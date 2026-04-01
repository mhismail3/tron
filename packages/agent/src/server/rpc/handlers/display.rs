//! Display handlers: `stopStream`.
//!
//! Allows iOS clients to stop an active display stream on demand.
//! Uses ProcessManager to find and cancel the stream by label.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Stop an active display stream by stream ID.
///
/// Looks up the stream process by label (`display_stream:{streamId}`) via
/// ProcessManager and cancels it. The `sessionId` parameter is required so
/// the process can be found in the correct session scope.
pub struct StopStreamHandler;

#[async_trait]
impl MethodHandler for StopStreamHandler {
    #[instrument(skip(self, ctx), fields(method = "display.stopStream"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let stream_id = require_string_param(params.as_ref(), "streamId")?;
        let session_id = params
            .as_ref()
            .and_then(|p| p.get("sessionId"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let stopped = if let Some(ref pm) = ctx.process_manager {
            let label = format!("display_stream:{stream_id}");
            if let Some(process_id) = pm.find_by_label(session_id, &label) {
                let _ = pm.cancel_process(&process_id);
                true
            } else {
                false
            }
        } else {
            false
        };

        Ok(serde_json::json!({
            "streamId": stream_id,
            "stopped": stopped,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::runtime::orchestrator::process_manager::ProcessManager;
    use crate::tools::traits::{ManagedProcessConfig, ProcessKind, ProcessManagerOps};
    use serde_json::json;
    use std::sync::Arc;

    fn boxed_delayed(ms: u64) -> std::pin::Pin<Box<dyn std::future::Future<Output = crate::tools::traits::ManagedProcessResult> + Send>> {
        Box::pin(async move {
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            crate::tools::traits::ManagedProcessResult {
                process_id: String::new(),
                output: "stream ended".into(),
                exit_code: None,
                duration_ms: ms,
                timed_out: false,
                cancelled: false,
                blob_id: None,
            }
        })
    }

    #[tokio::test]
    async fn stop_stream_via_process_manager() {
        let pm = Arc::new(ProcessManager::new());
        let config = ManagedProcessConfig {
            label: "display_stream:s1".into(),
            kind: ProcessKind::DisplayStream,
            timeout_ms: None,
            blocking_timeout_ms: None,
            sandbox: false,
        };
        let _ = pm.spawn_managed("sess-1", "tc1", config, boxed_delayed(5000)).await.unwrap();

        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let result = StopStreamHandler
            .handle(Some(json!({"streamId": "s1", "sessionId": "sess-1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["stopped"], true);
    }

    #[tokio::test]
    async fn stop_stream_nonexistent_returns_false() {
        let pm = Arc::new(ProcessManager::new());
        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let result = StopStreamHandler
            .handle(Some(json!({"streamId": "nope", "sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["stopped"], false);
    }

    #[tokio::test]
    async fn stop_stream_no_pm_returns_false() {
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
