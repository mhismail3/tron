//! Process management RPC handlers.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Promote a foreground process to background.
pub struct PromoteHandler;

#[async_trait]
impl MethodHandler for PromoteHandler {
    #[instrument(skip(self, ctx), fields(method = "process.promote"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let process_id = require_string_param(params.as_ref(), "processId")?;

        let pm = ctx.process_manager.as_ref().ok_or_else(|| {
            RpcError::Internal {
                message: "Process manager not available".into(),
            }
        })?;

        pm.promote_to_background(&process_id).map_err(|e| RpcError::Internal {
            message: format!("Failed to promote: {e}"),
        })?;

        Ok(serde_json::json!({
            "processId": process_id,
            "promoted": true,
        }))
    }
}

/// Cancel a running process.
pub struct CancelHandler;

#[async_trait]
impl MethodHandler for CancelHandler {
    #[instrument(skip(self, ctx), fields(method = "process.cancel"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let process_id = require_string_param(params.as_ref(), "processId")?;

        let pm = ctx.process_manager.as_ref().ok_or_else(|| {
            RpcError::Internal {
                message: "Process manager not available".into(),
            }
        })?;

        pm.cancel_process(&process_id).map_err(|e| RpcError::Internal {
            message: format!("Failed to cancel: {e}"),
        })?;

        Ok(serde_json::json!({
            "processId": process_id,
            "cancelled": true,
        }))
    }
}

/// List processes for a session.
pub struct ListHandler;

#[async_trait]
impl MethodHandler for ListHandler {
    #[instrument(skip(self, ctx), fields(method = "process.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let pm = ctx.process_manager.as_ref().ok_or_else(|| {
            RpcError::Internal {
                message: "Process manager not available".into(),
            }
        })?;

        let processes = pm.list_processes(&session_id);
        Ok(serde_json::json!({
            "processes": processes,
        }))
    }
}

/// Get status of a specific process.
pub struct StatusHandler;

#[async_trait]
impl MethodHandler for StatusHandler {
    #[instrument(skip(self, ctx), fields(method = "process.status"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let process_id = require_string_param(params.as_ref(), "processId")?;

        let pm = ctx.process_manager.as_ref().ok_or_else(|| {
            RpcError::Internal {
                message: "Process manager not available".into(),
            }
        })?;

        match pm.get_result(&process_id) {
            Some(result) => Ok(serde_json::json!({
                "processId": process_id,
                "state": "completed",
                "result": result,
            })),
            None => {
                // Check if it's in the active list.
                let all: Vec<_> = pm.list_processes("")
                    .into_iter()
                    .filter(|p| p.process_id == process_id)
                    .collect();
                if let Some(info) = all.first() {
                    Ok(serde_json::json!({
                        "processId": process_id,
                        "state": info.state,
                        "label": info.label,
                        "elapsedMs": info.elapsed_ms,
                    }))
                } else {
                    Err(RpcError::InvalidParams {
                        message: format!("Process not found: {process_id}"),
                    })
                }
            }
        }
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
                output: "done".into(),
                exit_code: Some(0),
                duration_ms: ms,
                timed_out: false,
                cancelled: false,
                blob_id: None,
            }
        })
    }

    #[tokio::test]
    async fn rpc_process_cancel_running() {
        let pm = Arc::new(ProcessManager::new());
        let config = ManagedProcessConfig {
            label: "test".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            blocking_timeout_ms: None,
            sandbox: false,
        };
        let h = pm.spawn_managed("s1", "tc1", config, boxed_delayed(5000)).await.unwrap();

        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm.clone());

        let result = CancelHandler
            .handle(Some(json!({"processId": h.process_id})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["cancelled"], true);
    }

    #[tokio::test]
    async fn rpc_process_cancel_nonexistent() {
        let pm = Arc::new(ProcessManager::new());
        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let err = CancelHandler
            .handle(Some(json!({"processId": "proc-nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn rpc_process_list_session() {
        let pm = Arc::new(ProcessManager::new());
        let config = ManagedProcessConfig {
            label: "test-cmd".into(),
            kind: ProcessKind::Shell,
            timeout_ms: None,
            blocking_timeout_ms: None,
            sandbox: false,
        };
        let _ = pm.spawn_managed("s1", "tc1", config, boxed_delayed(5000)).await.unwrap();

        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let result = ListHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        let processes = result["processes"].as_array().unwrap();
        assert_eq!(processes.len(), 1);
    }

    #[tokio::test]
    async fn rpc_process_list_empty() {
        let pm = Arc::new(ProcessManager::new());
        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let result = ListHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        let processes = result["processes"].as_array().unwrap();
        assert!(processes.is_empty());
    }

    #[tokio::test]
    async fn rpc_process_no_pm_returns_error() {
        let ctx = make_test_context();
        let err = CancelHandler
            .handle(Some(json!({"processId": "proc-1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn rpc_process_promote_missing_param() {
        let pm = Arc::new(ProcessManager::new());
        let mut ctx = make_test_context();
        ctx.process_manager = Some(pm);

        let err = PromoteHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
