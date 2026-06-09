use super::*;

pub(super) struct EchoExternalInvoker;

#[async_trait]
impl super::external::ExternalWorkerInvoker for EchoExternalInvoker {
    async fn invoke(&self, invoke: super::WorkerInvoke) -> Result<super::WorkerInvocationResult> {
        Ok(super::WorkerInvocationResult {
            invocation_id: invoke.invocation_id,
            result: Some(json!({
                "functionId": invoke.function_id,
                "payload": invoke.payload,
                "traceId": invoke.trace_id,
            })),
            error: None,
        })
    }
}

pub(super) struct DisconnectExternalInvoker;

#[async_trait]
impl super::external::ExternalWorkerInvoker for DisconnectExternalInvoker {
    async fn invoke(&self, invoke: super::WorkerInvoke) -> Result<super::WorkerInvocationResult> {
        Ok(super::WorkerInvocationResult {
            invocation_id: invoke.invocation_id,
            result: None,
            error: Some(json!({
                "code": "WORKER_DISCONNECTED",
                "message": "test disconnect before worker result"
            })),
        })
    }
}
