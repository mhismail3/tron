//! Primitive substrate store methods exposed through `EngineHostHandle`.

use super::*;

impl EngineHostHandle {
    /// Read durable engine rows for one session without invoking any functions.
    pub(crate) async fn replay_snapshot(
        &self,
        session_id: &str,
    ) -> Result<crate::engine::durability::replay::EngineReplaySnapshot> {
        let (invocations, idempotency_entries, streams, queue) = {
            let host = self.inner.lock().await;
            (
                host.catalog.ledger_invocations_by_session(session_id)?,
                host.catalog.ledger_idempotency_by_session(session_id)?,
                host.primitives.streams.clone(),
                host.primitives.queue.clone(),
            )
        };

        let stream_events = streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .list_by_session(session_id)?;
        let queue_items = queue
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .list_by_session(session_id)?;

        Ok(crate::engine::durability::replay::EngineReplaySnapshot {
            invocations,
            idempotency_entries,
            streams: stream_events,
            queue_items,
        })
    }

    /// Inspect one authority grant through the engine-owned store.
    pub async fn inspect_authority_grant(
        &self,
        grant_id: &AuthorityGrantId,
    ) -> Result<Option<EngineGrant>> {
        let store = self.inner.lock().await.primitives.grants.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .inspect(grant_id)
    }

    /// Derive a narrower grant through the engine-owned grant store.
    pub async fn derive_authority_grant(&self, request: DeriveGrant) -> Result<EngineGrant> {
        let store = self.inner.lock().await.primitives.grants.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .derive(request)
    }

    /// Return the deterministic policy hash for a stored grant.
    pub async fn authority_grant_policy_hash(&self, grant_id: &AuthorityGrantId) -> Result<String> {
        let grant = self
            .inspect_authority_grant(grant_id)
            .await?
            .ok_or_else(|| EngineError::PolicyViolation(format!("unknown grant {grant_id}")))?;
        Ok(crate::engine::authority::grants::grant_policy_hash(&grant))
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

    /// Register a resource type through the engine-owned resource store.
    pub async fn register_resource_type(
        &self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .register_type(request)
    }

    /// Create a typed resource through the engine-owned resource store.
    pub async fn create_resource(&self, request: CreateResource) -> Result<EngineResource> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .create(request)
    }

    /// Append or compare-and-set a typed resource version.
    pub async fn update_resource(&self, request: UpdateResource) -> Result<EngineResourceVersion> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .update(request)
    }

    /// Create a typed edge between two resources.
    pub async fn link_resources(&self, request: LinkResources) -> Result<EngineResourceLink> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .link(request)
    }

    /// List outgoing resource links for one relation with a caller-supplied cap.
    pub(crate) async fn list_resource_links_for_source(
        &self,
        source_resource_id: &str,
        relation: &str,
        limit: usize,
    ) -> Result<Vec<EngineResourceLink>> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list_links_for_source(source_resource_id, relation, limit)
    }

    /// Inspect one resource and its version/link/event history.
    pub async fn inspect_resource(
        &self,
        resource_id: &str,
    ) -> Result<Option<EngineResourceInspection>> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .inspect(resource_id)
    }

    /// List typed resources from the engine-owned resource store.
    pub async fn list_resources(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list(filter)
    }

    /// Scan typed resources for crate-internal maintenance without the public
    /// list cap. Callers must keep filtering and mutations scoped.
    pub(crate) async fn scan_resources_internal(
        &self,
        filter: ListResources,
    ) -> Result<Vec<EngineResource>> {
        let store = self.inner.lock().await.primitives.resources.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list_internal_scan(filter)
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

    /// Complete a queue item and append an attempt record.
    pub async fn complete_queue_item_with_attempt(
        &self,
        receipt_id: &str,
        attempt: EngineQueueAttemptRecord,
    ) -> Result<bool> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .complete_with_attempt(receipt_id, attempt)
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

    /// Fail a queue item and append an attempt record.
    pub async fn fail_queue_item_with_attempt(
        &self,
        receipt_id: &str,
        max_attempts: u32,
        backoff_ms: i64,
        attempt: EngineQueueAttemptRecord,
    ) -> Result<bool> {
        let store = self.inner.lock().await.primitives.queue.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .fail_with_attempt(receipt_id, max_attempts, backoff_ms, attempt)
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
