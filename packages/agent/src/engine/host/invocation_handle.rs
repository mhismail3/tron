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
        if invocation.function_id.as_str() == APPROVAL_REQUEST_FUNCTION {
            return self.invoke_approval_request_unlocked(invocation).await;
        }
        if invocation.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
            return self.invoke_approval_resolve_unlocked(invocation).await;
        }
        if invocation.function_id.as_str() == primitives::ui::SUBMIT_ACTION_FUNCTION {
            return self.invoke_ui_submit_action_unlocked(invocation).await;
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
            || invocation.function_id.as_str() == APPROVAL_REQUEST_FUNCTION
            || invocation.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION
            || invocation.function_id.as_str() == primitives::ui::SUBMIT_ACTION_FUNCTION
            || invocation.function_id.namespace() == ENGINE_WORKER_ID
            || is_host_dispatched_primitive_function(&invocation.function_id)
        {
            return QueueTargetInvocation {
                result: self.invoke(invocation).await,
                recorded_invocation: true,
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
                };
            }
        };

        self.execute_prepared_regular_with_recording_policy(
            *prepared,
            InvocationRecordingPolicy::SkipRetryableQueueDeliveryFailure,
        )
        .await
    }

    async fn invoke_approval_request_unlocked(&self, invocation: Invocation) -> InvocationResult {
        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };
        let request = match approval_request_from_invocation(&prepared.invocation) {
            Ok(request) => request,
            Err(error) => {
                return self
                    .finish_prepared_approval_request(*prepared, Err(error))
                    .await;
            }
        };
        let result = self
            .request_approval(request)
            .await
            .map(|record| json!({ "approval": record }));
        self.finish_prepared_approval_request(*prepared, result)
            .await
    }

    async fn finish_prepared_approval_request(
        &self,
        prepared: PreparedSyncInvocation,
        result: Result<Value>,
    ) -> InvocationResult {
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(prepared, result)
    }

    async fn invoke_prepared_regular_unlocked(&self, invocation: Invocation) -> InvocationResult {
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
                compensation_status,
            );
        self.record_compensation_for_result(
            &compensation_invocation,
            compensation_contract,
            &result,
            lease_ids,
        )
        .await;
        QueueTargetInvocation {
            result,
            recorded_invocation: true,
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
    ) {
        let Some(contract) = contract else {
            return;
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
                            "compensation": record,
                        }),
                        visibility: VisibilityScope::System,
                        session_id: None,
                        workspace_id: None,
                        producer: "compensation".to_owned(),
                        trace_id: Some(result.trace_id.clone()),
                        parent_invocation_id: Some(result.invocation_id.clone()),
                    })
                    .await;
            }
            Err(error) => {
                tracing::error!(?error, "failed to record engine compensation contract");
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
    ///
    /// Approval-required autonomous writes still need a durable target
    /// invocation row so observability can show which canonical capability was
    /// attempted, even though the domain handler never ran.
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
            PreparedDelegatedChild::UiSubmit(child) => {
                self.invoke_ui_submit_action_unlocked(*child).await
            }
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Execute(child)) => {
                if child.invocation.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
                    self.execute_prepared_approval_resolve(*child).await
                } else {
                    self.execute_prepared_regular(*child).await
                }
            }
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Finished(result)) => {
                *result
            }
        };

        let mut host = self.inner.lock().await;
        let value = delegated_invoke_value(host.catalog.revision(), &child_result);
        host.finish_meta_invocation(
            prepared.meta_invocation,
            prepared.meta_function,
            Ok(value),
            None,
        )
    }

    async fn invoke_ui_submit_action_unlocked(
        &self,
        mut invocation: Invocation,
    ) -> InvocationResult {
        let prepared = {
            let mut host = self.inner.lock().await;
            let function = match host.prepare_meta_invocation(&mut invocation) {
                Ok(function) => function,
                Err(err) => return host.meta_error(&invocation, err),
            };
            let idempotency = match host
                .catalog
                .begin_invocation_idempotency(&function, &invocation)
            {
                InvocationIdempotencyDecision::None => None,
                InvocationIdempotencyDecision::Reserved(reservation) => Some(reservation),
                InvocationIdempotencyDecision::Finished { result, scope } => {
                    return host
                        .catalog
                        .record_invocation_result(&invocation, result, scope);
                }
            };
            match primitives::ui::action_child_invocation(&*host, &invocation) {
                Ok(child) => Ok((invocation.clone(), function, idempotency, child)),
                Err(err) => Err(host.finish_meta_invocation(
                    invocation.clone(),
                    function,
                    Err(err),
                    idempotency,
                )),
            }
        };
        let (meta_invocation, meta_function, idempotency, child) = match prepared {
            Ok(prepared) => prepared,
            Err(result) => return result,
        };
        let child = if child.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(child)
        } else if is_host_dispatched_primitive_function(&child.function_id) {
            PreparedSyncInvocationDecision::Finished(Box::new(
                self.inner
                    .lock()
                    .await
                    .invoke_sync_host_dispatched_primitive(child),
            ))
        } else {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(child)
        };
        let child_result = match child {
            PreparedSyncInvocationDecision::Execute(child) => {
                if child.invocation.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
                    self.execute_prepared_approval_resolve(*child).await
                } else {
                    self.execute_prepared_regular(*child).await
                }
            }
            PreparedSyncInvocationDecision::Finished(result) => *result,
        };
        let submit_value = if let Some(error) = child_result.error.clone() {
            Err(error)
        } else {
            Ok(primitives::ui::submit_action_result_value(
                &meta_invocation,
                &child_result,
            ))
        };
        self.inner.lock().await.finish_meta_invocation(
            meta_invocation,
            meta_function,
            submit_value,
            idempotency,
        )
    }

    async fn invoke_approval_resolve_unlocked(&self, invocation: Invocation) -> InvocationResult {
        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };
        self.execute_prepared_approval_resolve(*prepared).await
    }

    async fn execute_prepared_approval_resolve(
        &self,
        prepared: PreparedSyncInvocation,
    ) -> InvocationResult {
        let approval_id = match required_str(&prepared.invocation.payload, "approvalId") {
            Ok(value) => value.to_owned(),
            Err(error) => {
                return self
                    .finish_prepared_approval_resolve(prepared, Err(error))
                    .await;
            }
        };
        let decision = match required_str(&prepared.invocation.payload, "decision")
            .and_then(parse_approval_decision)
        {
            Ok(decision) => decision,
            Err(error) => {
                return self
                    .finish_prepared_approval_resolve(prepared, Err(error))
                    .await;
            }
        };
        if !can_resolve_approval(&prepared.invocation.causal_context.actor_kind) {
            return self
                .finish_prepared_approval_resolve(
                    prepared,
                    Err(EngineError::PolicyViolation(
                        "approval resolution requires an admin, system, or user-authorized actor"
                            .to_owned(),
                    )),
                )
                .await;
        }
        let resolver = prepared.invocation.causal_context.actor_id.clone();
        let approval_store = self.inner.lock().await.primitives.approvals.clone();
        let mut resolved = match {
            approval_store
                .lock()
                .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))
                .and_then(|mut approvals| approvals.resolve(&approval_id, decision, resolver))
        } {
            Ok(record) => record,
            Err(error) => {
                return self
                    .finish_prepared_approval_resolve(prepared, Err(error))
                    .await;
            }
        };

        let child_result = if decision == ApprovalDecision::Approve
            && resolved.status == ApprovalStatus::Approved
        {
            let child_invocation = Invocation::new_sync(
                resolved.function_id.clone(),
                resolved.payload.clone(),
                resolved.causal_context(),
            )
            .with_delivery_mode(resolved.delivery_mode);
            let result = self
                .invoke_prepared_regular_unlocked(child_invocation)
                .await;
            let completed = approval_store
                .lock()
                .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))
                .and_then(|mut approvals| approvals.complete(&approval_id, &result));
            match completed {
                Ok(record) => {
                    resolved = record;
                    Some(result)
                }
                Err(error) => {
                    return self
                        .finish_prepared_approval_resolve(prepared, Err(error))
                        .await;
                }
            }
        } else {
            None
        };

        let child_value = child_result.as_ref().map(invocation_result_value);
        let _ = self
            .publish_stream_event(PublishStreamEvent {
                topic: "approvals".to_owned(),
                payload: json!({
                    "type": "approval.resolved",
                    "approval": resolved,
                    "child": child_value,
                }),
                visibility: resolved
                    .session_id
                    .as_ref()
                    .map_or(VisibilityScope::System, |_| VisibilityScope::Session),
                session_id: resolved.session_id.clone(),
                workspace_id: resolved.workspace_id.clone(),
                producer: APPROVAL_RESOLVE_FUNCTION.to_owned(),
                trace_id: Some(prepared.invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(prepared.invocation.id.clone()),
            })
            .await;

        self.finish_prepared_approval_resolve(
            prepared,
            Ok(json!({
                "approval": resolved,
                "child": child_result.map(|result| invocation_result_value(&result)),
            })),
        )
        .await
    }

    async fn finish_prepared_approval_resolve(
        &self,
        prepared: PreparedSyncInvocation,
        result: Result<Value>,
    ) -> InvocationResult {
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(prepared, result)
    }
}
