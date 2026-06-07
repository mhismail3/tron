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
        if invocation.function_id.namespace() == ENGINE_WORKER_ID {
            return self.inner.lock().await.invoke(invocation).await;
        }
        if is_host_dispatched_primitive_function(&invocation.function_id) {
            return self.inner.lock().await.invoke(invocation).await;
        }

        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };

        self.execute_prepared_regular(*prepared).await
    }

    /// Invoke a target claimed by the engine queue runtime.
    ///
    /// Retryable non-mutating worker transport failures return an error result
    /// without committing a target invocation row; the queue lifecycle event is
    /// the durable truth for that delivery attempt.
    pub(in crate::engine) async fn invoke_queue_target(
        &self,
        invocation: Invocation,
    ) -> QueueTargetInvocation {
        if invocation.function_id.as_str() == INVOKE_FUNCTION
            || invocation.function_id.namespace() == ENGINE_WORKER_ID
            || is_host_dispatched_primitive_function(&invocation.function_id)
        {
            return QueueTargetInvocation {
                result: self.invoke(invocation).await,
                recorded_invocation: true,
                resource_lease_ids: Vec::new(),
                compensation_status: None,
                compensation_id: None,
            };
        }

        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => {
                return QueueTargetInvocation {
                    result: *result,
                    recorded_invocation: true,
                    resource_lease_ids: Vec::new(),
                    compensation_status: None,
                    compensation_id: None,
                };
            }
        };

        self.execute_prepared_regular_with_recording_policy(
            *prepared,
            InvocationRecordingPolicy::SkipRetryableQueueDeliveryFailure,
        )
        .await
    }

    /// Invoke a target prepared by the trigger runtime.
    pub(in crate::engine) async fn invoke_trigger_target(
        &self,
        invocation: Invocation,
    ) -> InvocationResult {
        if invocation.delivery_mode == DeliveryMode::Sync {
            return self.invoke(invocation).await;
        }

        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_trigger_target_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };
        self.execute_prepared_regular(*prepared).await
    }

    async fn execute_prepared_regular(&self, prepared: PreparedSyncInvocation) -> InvocationResult {
        self.execute_prepared_regular_with_recording_policy(
            prepared,
            InvocationRecordingPolicy::RecordAll,
        )
        .await
        .result
    }

    async fn execute_prepared_regular_with_recording_policy(
        &self,
        prepared: PreparedSyncInvocation,
        recording_policy: InvocationRecordingPolicy,
    ) -> QueueTargetInvocation {
        let compensation_contract = prepared.function.compensation.clone();
        let compensation_invocation = prepared.invocation.clone();
        let lease_result = self.acquire_prepared_resource_lease(&prepared).await;
        let mut lease_ids = Vec::new();
        let handler_result = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = self.invoke_prepared_handler(&prepared).await;
                release_after_primary(self.release_resource_lease(&lease.lease_id).await, result)
            }
            Ok(None) => self.invoke_prepared_handler(&prepared).await,
            Err(error) => Err(error),
        };
        if recording_policy == InvocationRecordingPolicy::SkipRetryableQueueDeliveryFailure
            && let Some(error) = queue_retryable_delivery_failure(&prepared, &handler_result)
        {
            return QueueTargetInvocation {
                result: InvocationResult::error(
                    &prepared.invocation,
                    prepared.function.owner_worker.clone(),
                    prepared.function.revision,
                    prepared.invocation.causal_context.catalog_revision,
                    error,
                ),
                recorded_invocation: false,
                resource_lease_ids: Vec::new(),
                compensation_status: None,
                compensation_id: None,
            };
        }
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
        let resource_lease_ids = lease_ids.clone();
        let compensation = self
            .record_compensation_for_result(
                &compensation_invocation,
                compensation_contract,
                &result,
                lease_ids,
            )
            .await;
        let compensation_id = compensation
            .as_ref()
            .map(|record| record.compensation_id.clone());
        let compensation_status = compensation
            .as_ref()
            .map(|record| record.status.as_str().to_owned())
            .or(compensation_status);
        QueueTargetInvocation {
            result,
            recorded_invocation: true,
            resource_lease_ids,
            compensation_status,
            compensation_id,
        }
    }

    async fn invoke_prepared_handler(&self, prepared: &PreparedSyncInvocation) -> Result<Value> {
        AssertUnwindSafe(prepared.handler.invoke(prepared.invocation.clone()))
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
                self.execute_prepared_regular(*child).await
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
