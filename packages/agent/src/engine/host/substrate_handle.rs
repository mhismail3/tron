//! Primitive substrate store methods exposed through `EngineHostHandle`.

use super::*;
use crate::engine::EngineApprovalTargetMetadata;

impl EngineHostHandle {
    /// Create or replay an approval request and publish a pending approval
    /// stream event only for a newly created pending approval.
    pub async fn request_approval(
        &self,
        mut request: EngineApprovalRequest,
    ) -> Result<EngineApprovalRecord> {
        if request.target_metadata.is_none() {
            request.target_metadata = self
                .inner
                .lock()
                .await
                .catalog
                .function(&request.function_id)
                .map(EngineApprovalTargetMetadata::from_function);
        }
        let store = self.inner.lock().await.primitives.approvals.clone();
        let outcome = store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .request(request)?;
        let record = outcome.record;
        if outcome.created {
            let _ = self
                .publish_stream_event(PublishStreamEvent {
                    topic: "approvals".to_owned(),
                    payload: json!({
                        "type": "approval.pending",
                        "approval": record,
                    }),
                    visibility: record
                        .session_id
                        .as_ref()
                        .map_or(VisibilityScope::System, |_| VisibilityScope::Session),
                    session_id: record.session_id.clone(),
                    workspace_id: record.workspace_id.clone(),
                    producer: APPROVAL_REQUEST_FUNCTION.to_owned(),
                    trace_id: Some(record.trace_id.clone()),
                    parent_invocation_id: record.parent_invocation_id.clone(),
                })
                .await;
        }
        Ok(record)
    }

    /// Get one approval record.
    pub async fn get_approval(&self, approval_id: &str) -> Result<Option<EngineApprovalRecord>> {
        let store = self.inner.lock().await.primitives.approvals.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .get(approval_id)
    }

    /// List approval records.
    pub async fn list_approvals(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        let store = self.inner.lock().await.primitives.approvals.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .list(status, session_id, limit)
    }

    /// Acquire a high-risk resource lease and publish a lease lifecycle stream
    /// event. This is a primitive API for domain functions that mutate shared
    /// resources and need fail-closed exclusion.
    pub async fn acquire_resource_lease(
        &self,
        request: AcquireResourceLease,
    ) -> Result<EngineResourceLease> {
        let store = self.inner.lock().await.primitives.leases.clone();
        let lease = {
            store
                .lock()
                .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
                .acquire(request)?
        };
        let _ = self
            .publish_stream_event(PublishStreamEvent {
                topic: "resource.leases".to_owned(),
                payload: json!({
                    "type": "resource_lease.acquired",
                    "lease": lease,
                }),
                visibility: VisibilityScope::System,
                session_id: None,
                workspace_id: None,
                producer: "resource_lease".to_owned(),
                trace_id: Some(lease.trace_id.clone()),
                parent_invocation_id: Some(lease.holder_invocation_id.clone()),
            })
            .await;
        Ok(lease)
    }

    /// Release a high-risk resource lease and publish a lifecycle stream event.
    pub async fn release_resource_lease(
        &self,
        lease_id: &str,
    ) -> Result<Option<EngineResourceLease>> {
        let store = self.inner.lock().await.primitives.leases.clone();
        let lease = {
            store
                .lock()
                .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
                .release(lease_id)?
        };
        if let Some(lease) = lease.as_ref() {
            let _ = self
                .publish_stream_event(PublishStreamEvent {
                    topic: "resource.leases".to_owned(),
                    payload: json!({
                        "type": "resource_lease.released",
                        "lease": lease,
                    }),
                    visibility: VisibilityScope::System,
                    session_id: None,
                    workspace_id: None,
                    producer: "resource_lease".to_owned(),
                    trace_id: Some(lease.trace_id.clone()),
                    parent_invocation_id: Some(lease.holder_invocation_id.clone()),
                })
                .await;
        }
        Ok(lease)
    }

    /// Get a high-risk resource lease record.
    pub async fn get_resource_lease(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        let store = self.inner.lock().await.primitives.leases.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
            .get(lease_id)
    }

    /// Get a durable compensation record.
    pub async fn get_compensation_record(
        &self,
        compensation_id: &str,
    ) -> Result<Option<EngineCompensationRecord>> {
        let store = self.inner.lock().await.primitives.compensation.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))?
            .get(compensation_id)
    }

    /// List durable compensation records.
    pub async fn list_compensation_records(&self) -> Result<Vec<EngineCompensationRecord>> {
        let store = self.inner.lock().await.primitives.compensation.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))?
            .list()
    }

    /// Publish directly to the engine stream store.
    pub async fn publish_stream_event(&self, event: PublishStreamEvent) -> Result<StreamCursor> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .publish(event)
    }

    /// Subscribe directly to the engine stream store.
    pub async fn subscribe_stream(
        &self,
        subscription_id: String,
        topic: String,
        cursor: StreamCursor,
        visibility: VisibilityScope,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<EngineStreamSubscription> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .subscribe(
                subscription_id,
                topic,
                cursor,
                visibility,
                session_id,
                workspace_id,
            )
    }

    /// Return the latest stream cursor for one topic.
    pub async fn latest_stream_cursor(&self, topic: &str) -> Result<StreamCursor> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .latest_cursor(topic)
    }

    /// Poll the engine stream store.
    pub async fn poll_stream(
        &self,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .poll(subscription_id, after, limit, actor)
    }

    /// Acknowledge delivered stream events and persist the subscription cursor.
    pub async fn acknowledge_stream(
        &self,
        subscription_id: &str,
        cursor: StreamCursor,
    ) -> Result<EngineStreamSubscription> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .acknowledge(subscription_id, cursor)
    }

    /// Unsubscribe directly from the engine stream store.
    pub async fn unsubscribe_stream(&self, subscription_id: &str) -> Result<bool> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .unsubscribe(subscription_id)
    }

    /// Enqueue directly into the engine queue store.
    pub async fn enqueue_invocation(&self, request: EnqueueInvocation) -> Result<EngineQueueItem> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .enqueue(request)
    }

    /// Claim a queue item.
    pub async fn claim_queue_item(
        &self,
        queue: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .claim(queue, lease_owner, lease_ms)
    }

    /// Claim a queue item by receipt.
    pub async fn claim_queue_item_by_receipt(
        &self,
        receipt_id: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .claim_by_receipt(receipt_id, lease_owner, lease_ms)
    }

    /// Complete a queue item.
    pub async fn complete_queue_item(&self, receipt_id: &str) -> Result<bool> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .complete(receipt_id)
    }

    /// Fail a queue item.
    pub async fn fail_queue_item(
        &self,
        receipt_id: &str,
        max_attempts: u32,
        backoff_ms: i64,
    ) -> Result<bool> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .fail(receipt_id, max_attempts, backoff_ms)
    }

    /// Inspect a queue item by receipt.
    pub async fn get_queue_item(&self, receipt_id: &str) -> Result<Option<EngineQueueItem>> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .get(receipt_id)
    }

    /// Record a trigger handoff that enqueued the target invocation.
    pub async fn record_enqueued_invocation(
        &self,
        invocation: Invocation,
        item: &EngineQueueItem,
    ) -> InvocationResult {
        let mut host = self.inner.lock().await;
        let Some(function) = host.catalog.function(&invocation.function_id).cloned() else {
            let result = InvocationResult::error(
                &invocation,
                WorkerId::new("missing").expect("valid static id"),
                FunctionRevision(0),
                host.catalog.revision(),
                EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                },
            );
            return host
                .catalog
                .record_invocation_result(&invocation, result, None);
        };
        let result = InvocationResult::success(
            &invocation,
            function.owner_worker.clone(),
            function.revision,
            host.catalog.revision(),
            json!({
                "queued": true,
                "receiptId": item.receipt_id,
                "queue": item.queue,
            }),
        );
        host.catalog
            .record_invocation_result(&invocation, result, None)
    }
}
