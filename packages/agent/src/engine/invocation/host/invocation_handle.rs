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
    /// cancellation contract. Cancellation is observed after any resource
    /// lease is acquired so the normal release, durable outcome, idempotency,
    /// and compensation lifecycle still completes.
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
        let compensation_contract = prepared.function.compensation.clone();
        let compensation_invocation = prepared.invocation.clone();
        let lease_result = self.acquire_prepared_resource_lease(&prepared).await;
        let mut lease_ids = Vec::new();
        let handler_result = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = self.invoke_prepared_handler(&prepared, cancellation).await;
                release_after_primary(self.release_resource_lease(&lease.lease_id).await, result)
            }
            Ok(None) => self.invoke_prepared_handler(&prepared, cancellation).await,
            Err(error) => Err(error),
        };
        let compensation_status = prepared
            .function
            .compensation
            .as_ref()
            .map(|_| "recorded".to_owned());
        let result = self
            .inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation_with_contracts(
                prepared,
                handler_result,
                lease_ids.clone(),
                compensation_status.clone(),
            );
        let _ = self
            .record_compensation_for_result(
                &compensation_invocation,
                compensation_contract,
                &result,
                lease_ids,
            )
            .await;
        result
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

    async fn acquire_prepared_resource_lease(
        &self,
        prepared: &PreparedSyncInvocation,
    ) -> Result<Option<EngineResourceLease>> {
        let Some(requirement) = &prepared.function.resource_lease else {
            return Ok(None);
        };
        let request = lease_request_from_requirement(requirement, &prepared.invocation)?;
        self.acquire_resource_lease(request).await.map(Some)
    }

    async fn record_compensation_for_result(
        &self,
        invocation: &Invocation,
        contract: Option<CompensationContract>,
        result: &InvocationResult,
        resource_lease_ids: Vec<String>,
    ) -> Option<EngineCompensationRecord> {
        let Some(contract) = contract else {
            return None;
        };
        let record = compensation_record(invocation, result, contract, resource_lease_ids);
        let store = self.inner.lock().await.primitives.compensation.clone();
        let stored = store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))
            .and_then(|mut store| store.record(record));
        match stored {
            Ok(record) => {
                let _ = self
                    .publish_stream_event(PublishStreamEvent {
                        topic: "compensation.records".to_owned(),
                        payload: json!({
                            "type": "compensation.recorded",
                            "compensation": record.clone(),
                        }),
                        visibility: VisibilityScope::System,
                        session_id: None,
                        workspace_id: None,
                        producer: "compensation".to_owned(),
                        trace_id: Some(result.trace_id.clone()),
                        parent_invocation_id: Some(result.invocation_id.clone()),
                    })
                    .await;
                Some(record)
            }
            Err(error) => {
                tracing::error!(?error, "failed to record engine compensation contract");
                None
            }
        }
    }

    /// Record a trigger dispatch attempt that failed before normal invocation
    /// preparation could attach a target function contract.
    pub async fn record_trigger_prepare_failure(
        &self,
        invocation: Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        error: EngineError,
    ) -> InvocationResult {
        self.record_policy_stopped_invocation(invocation, worker_id, function_revision, error)
            .await
    }

    /// Record an invocation that policy stopped before handler execution.
    pub async fn record_policy_stopped_invocation(
        &self,
        invocation: Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        error: EngineError,
    ) -> InvocationResult {
        let mut host = self.inner.lock().await;
        let result = InvocationResult::error(
            &invocation,
            worker_id,
            function_revision,
            host.catalog.revision(),
            error,
        );
        host.catalog
            .record_invocation_result(&invocation, result, None)
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
