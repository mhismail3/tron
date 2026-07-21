//! Invocation orchestration methods on `EngineHostHandle`.

use super::*;

impl EngineHostHandle {
    /// Invoke a function through the host boundary.
    ///
    /// Non-privileged functions are prepared under the host lock, executed
    /// outside it, then finished under the lock so long-running handlers do not
    /// block live discovery or catalog watches.
    pub async fn invoke(&self, invocation: Invocation) -> InvocationResult {
        let prepared = self.prepare_regular_invocation(invocation).await;
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };

        self.execute_prepared_regular(*prepared, None).await
    }

    /// Invoke a regular in-process function with cooperative handler cancellation.
    ///
    /// This path is the same regular function route with cooperative handler
    /// cancellation. The durable outcome and idempotency lifecycle still
    /// complete after cancellation is observed.
    pub(crate) async fn invoke_regular_cancellable(
        &self,
        invocation: Invocation,
        cancellation: &CancellationToken,
    ) -> Result<InvocationResult> {
        let prepared = self.prepare_regular_invocation(invocation).await;
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return Ok(*result),
        };

        Ok(self
            .execute_prepared_regular(*prepared, Some(cancellation))
            .await)
    }

    async fn prepare_regular_invocation(
        &self,
        invocation: Invocation,
    ) -> PreparedSyncInvocationDecision {
        self.inner
            .lock()
            .await
            .catalog
            .prepare_sync_invocation(invocation)
    }

    async fn execute_prepared_regular(
        &self,
        prepared: PreparedSyncInvocation,
        cancellation: Option<&CancellationToken>,
    ) -> InvocationResult {
        let handler_result = self.invoke_prepared_handler(&prepared, cancellation).await;
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(prepared, handler_result)
    }

    async fn invoke_prepared_handler(
        &self,
        prepared: &PreparedSyncInvocation,
        cancellation: Option<&CancellationToken>,
    ) -> Result<Value> {
        if cancellation.is_some_and(CancellationToken::is_cancelled) {
            return Err(EngineError::InvocationCancelled);
        }
        let handler = async {
            match cancellation {
                Some(cancellation) => {
                    prepared
                        .handler
                        .invoke_cancellable(prepared.invocation.clone(), cancellation)
                        .await
                }
                None => prepared.handler.invoke(prepared.invocation.clone()).await,
            }
        };
        AssertUnwindSafe(handler)
            .catch_unwind()
            .await
            .unwrap_or_else(|payload| {
                Err(EngineError::HandlerFailed(format!(
                    "handler panicked: {}",
                    panic_payload_message(payload)
                )))
            })
    }
}

fn panic_payload_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "unknown panic payload".to_owned()
    }
}
