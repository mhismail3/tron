use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use super::ExternalWorkerInvoker;
use crate::engine::invocation::model::{InProcessFunctionHandler, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::runtime::worker_protocol::WorkerInvoke;

pub(super) struct ExternalFunctionProxyHandler {
    pub(super) invoker: Arc<dyn ExternalWorkerInvoker>,
}

#[async_trait]
impl InProcessFunctionHandler for ExternalFunctionProxyHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let result = self
            .invoker
            .invoke(WorkerInvoke {
                invocation_id: invocation.id.clone(),
                function_id: invocation.function_id.clone(),
                payload: invocation.payload.clone(),
                actor_kind: invocation.causal_context.actor_kind.clone(),
                authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
                authority_scopes: invocation.causal_context.authority_scopes.clone(),
                trace_id: invocation.causal_context.trace_id.clone(),
                parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                trigger_id: invocation.causal_context.trigger_id.clone(),
                idempotency_key: invocation.causal_context.idempotency_key.clone(),
                session_id: invocation.causal_context.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                timeout_ms: 30_000,
            })
            .await?;
        if let Some(error) = result.error {
            if worker_result_error_code(&error) == Some("WORKER_DISCONNECTED") {
                return Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_DISCONNECTED".to_owned(),
                    message: worker_result_error_message(&error),
                });
            }
            return Err(EngineError::HandlerFailed(error.to_string()));
        }
        Ok(result.result.unwrap_or(Value::Null))
    }
}

fn worker_result_error_code(error: &Value) -> Option<&str> {
    error.get("code").and_then(Value::as_str)
}

fn worker_result_error_message(error: &Value) -> String {
    error
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| error.to_string())
}
