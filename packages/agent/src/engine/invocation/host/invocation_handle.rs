//! Invocation orchestration methods on `EngineHostHandle`.

use super::*;

impl EngineHostHandle {
    /// Invoke a function through the host boundary.
    ///
    /// Non-privileged functions are prepared under the host lock, executed
    /// outside it, then finished under the lock so long-running handlers do not
    /// block live discovery or catalog watches.
    pub async fn invoke(&self, invocation: Invocation) -> InvocationResult {
        if invocation.function_id.as_str() == INVOKE_FUNCTION {
            return self.invoke_delegated_unlocked(invocation).await;
        }
        if is_engine_meta_function(&invocation.function_id) {
            return self.inner.lock().await.invoke(invocation).await;
        }
        if is_host_dispatched_primitive_function(&invocation.function_id) {
            return self.inner.lock().await.invoke(invocation).await;
        }

        let prepared = self.prepare_regular_invocation(invocation).await;
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };

        self.execute_prepared_regular(*prepared, None).await
    }

    /// Invoke a regular in-process function with cooperative handler cancellation.
    ///
    /// This path deliberately excludes the privileged `engine::invoke` meta
    /// route, engine-owned/host-dispatched primitives, queued work, and trigger
    /// dispatch. Those targets retain their ordinary routing without this
    /// cancellation contract. The durable outcome and idempotency lifecycle
    /// still complete after cancellation is observed.
    pub(crate) async fn invoke_regular_cancellable(
        &self,
        invocation: Invocation,
        cancellation: &CancellationToken,
    ) -> Result<InvocationResult> {
        if invocation.function_id.as_str() == INVOKE_FUNCTION
            || invocation.function_id.namespace() == ENGINE_WORKER_ID
            || is_host_dispatched_primitive_function(&invocation.function_id)
        {
            return Err(EngineError::PolicyViolation(format!(
                "cooperative cancellation requires a regular in-process function, not {}",
                invocation.function_id
            )));
        }
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

    async fn invoke_delegated_unlocked(&self, invocation: Invocation) -> InvocationResult {
        let prepared = {
            let mut host = self.inner.lock().await;
            host.prepare_delegated_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedDelegatedInvocationDecision::Execute(prepared) => prepared,
            PreparedDelegatedInvocationDecision::Finished(result) => return *result,
        };

        let child_result = match prepared.child {
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Execute(child)) => {
                self.execute_prepared_regular(*child, None).await
            }
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Finished(result)) => {
                *result
            }
        };

        let mut host = self.inner.lock().await;
        let value = delegated_invoke_value(&child_result);
        host.finish_meta_invocation(
            prepared.meta_invocation,
            prepared.meta_function,
            Ok(value),
            None,
        )
    }
}

fn is_engine_meta_function(function_id: &FunctionId) -> bool {
    matches!(
        function_id.as_str(),
        DISCOVER_FUNCTION | INSPECT_FUNCTION | WATCH_FUNCTION | INVOKE_FUNCTION | PROMOTE_FUNCTION
    )
}
