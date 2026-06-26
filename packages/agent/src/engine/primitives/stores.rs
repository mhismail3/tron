//! Primitive store backends and host handle wiring.

use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};

use serde_json::Value;
use tokio::sync::Mutex as AsyncMutex;

use crate::engine::authority::compensation::{
    EngineCompensationRecord, InMemoryEngineCompensationStore, SqliteEngineCompensationStore,
};
use crate::engine::authority::grants::{
    EngineGrantStoreBackend, InMemoryEngineGrantStore, SqliteEngineGrantStore,
};
use crate::engine::authority::leases::{
    AcquireResourceLease, EngineResourceLease, InMemoryEngineResourceLeaseStore,
    SqliteEngineResourceLeaseStore,
};
use crate::engine::durability::queue::{
    EngineQueueAttemptRecord, EngineQueueItem, EnqueueInvocation, InMemoryEngineQueueStore,
    SqliteEngineQueueStore,
};
use crate::engine::durability::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceLink,
    EngineResourceTypeDefinition, EngineResourceVersion, InMemoryEngineResourceStore,
    LinkResources, ListResources, RegisterResourceType, SqliteEngineResourceStore, UpdateResource,
    builtin_module_manifest_resources, builtin_resource_type_definitions,
};
use crate::engine::durability::state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
use crate::engine::durability::streams::{
    EngineStreamPage, EngineStreamSubscription, InMemoryEngineStreamStore, PublishStreamEvent,
    SqliteEngineStreamStore, StreamActorScope, StreamCursor,
};
use crate::engine::invocation::host::{EngineHost, EngineHostHandle};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::types::VisibilityScope;

pub(in crate::engine) enum StreamStoreBackend {
    InMemory(InMemoryEngineStreamStore),
    Sqlite(SqliteEngineStreamStore),
}

impl StreamStoreBackend {
    pub(in crate::engine) fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        match self {
            Self::InMemory(store) => store.publish(event),
            Self::Sqlite(store) => store.publish(event),
        }
    }

    pub(in crate::engine) fn subscribe(
        &mut self,
        subscription_id: String,
        topic: String,
        cursor: StreamCursor,
        visibility: VisibilityScope,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<EngineStreamSubscription> {
        match self {
            Self::InMemory(store) => store.subscribe(
                subscription_id,
                topic,
                cursor,
                visibility,
                session_id,
                workspace_id,
            ),
            Self::Sqlite(store) => store.subscribe(
                subscription_id,
                topic,
                cursor,
                visibility,
                session_id,
                workspace_id,
            ),
        }
    }

    pub(in crate::engine) fn latest_cursor(&self, topic: &str) -> Result<StreamCursor> {
        match self {
            Self::InMemory(store) => Ok(store.latest_cursor(topic)),
            Self::Sqlite(store) => store.latest_cursor(topic),
        }
    }

    pub(in crate::engine) fn unsubscribe(&mut self, subscription_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.unsubscribe(subscription_id),
            Self::Sqlite(store) => store.unsubscribe(subscription_id),
        }
    }

    pub(in crate::engine) fn acknowledge(
        &mut self,
        subscription_id: &str,
        cursor: StreamCursor,
    ) -> Result<EngineStreamSubscription> {
        match self {
            Self::InMemory(store) => store.acknowledge(subscription_id, cursor),
            Self::Sqlite(store) => store.acknowledge(subscription_id, cursor),
        }
    }

    pub(in crate::engine) fn poll(
        &self,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        match self {
            Self::InMemory(store) => store.poll(subscription_id, after, limit, actor),
            Self::Sqlite(store) => store.poll(subscription_id, after, limit, actor),
        }
    }

    pub(in crate::engine) fn list_by_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<crate::engine::durability::streams::EngineStreamEvent>> {
        match self {
            Self::InMemory(store) => store.list_by_session(session_id),
            Self::Sqlite(store) => store.list_by_session(session_id),
        }
    }
}

pub(in crate::engine) enum StateStoreBackend {
    InMemory(InMemoryEngineStateStore),
    Sqlite(SqliteEngineStateStore),
}

impl StateStoreBackend {
    pub(in crate::engine) fn get(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<Option<EngineStateEntry>> {
        match self {
            Self::InMemory(store) => store.get(scope, namespace, key),
            Self::Sqlite(store) => store.get(scope, namespace, key),
        }
    }

    pub(in crate::engine) fn set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        value: Value,
    ) -> Result<EngineStateEntry> {
        match self {
            Self::InMemory(store) => store.set(scope, namespace, key, value),
            Self::Sqlite(store) => store.set(scope, namespace, key, value),
        }
    }

    pub(in crate::engine) fn compare_and_set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        expected_revision: Option<u64>,
        value: Value,
    ) -> Result<EngineStateEntry> {
        match self {
            Self::InMemory(store) => {
                store.compare_and_set(scope, namespace, key, expected_revision, value)
            }
            Self::Sqlite(store) => {
                store.compare_and_set(scope, namespace, key, expected_revision, value)
            }
        }
    }

    pub(in crate::engine) fn delete(
        &mut self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.delete(scope, namespace, key),
            Self::Sqlite(store) => store.delete(scope, namespace, key),
        }
    }

    pub(in crate::engine) fn list(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key_prefix: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineStateEntry>> {
        match self {
            Self::InMemory(store) => store.list(scope, namespace, key_prefix, limit),
            Self::Sqlite(store) => store.list(scope, namespace, key_prefix, limit),
        }
    }
}

pub(in crate::engine) enum QueueStoreBackend {
    InMemory(InMemoryEngineQueueStore),
    Sqlite(SqliteEngineQueueStore),
}

impl QueueStoreBackend {
    pub(in crate::engine) fn enqueue(
        &mut self,
        request: EnqueueInvocation,
    ) -> Result<EngineQueueItem> {
        match self {
            Self::InMemory(store) => store.enqueue(request),
            Self::Sqlite(store) => store.enqueue(request),
        }
    }

    pub(in crate::engine) fn claim(
        &mut self,
        queue: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.claim(queue, lease_owner, lease_ms),
            Self::Sqlite(store) => store.claim(queue, lease_owner, lease_ms),
        }
    }

    pub(in crate::engine) fn claim_by_receipt(
        &mut self,
        receipt_id: &str,
        lease_owner: &str,
        lease_ms: i64,
    ) -> Result<Option<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.claim_by_receipt(receipt_id, lease_owner, lease_ms),
            Self::Sqlite(store) => store.claim_by_receipt(receipt_id, lease_owner, lease_ms),
        }
    }

    pub(in crate::engine) fn complete(&mut self, receipt_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.complete(receipt_id),
            Self::Sqlite(store) => store.complete(receipt_id),
        }
    }

    pub(in crate::engine) fn complete_with_attempt(
        &mut self,
        receipt_id: &str,
        attempt: EngineQueueAttemptRecord,
    ) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.complete_with_attempt(receipt_id, Some(attempt)),
            Self::Sqlite(store) => store.complete_with_attempt(receipt_id, Some(attempt)),
        }
    }

    pub(in crate::engine) fn fail(
        &mut self,
        receipt_id: &str,
        max_attempts: u32,
        backoff_ms: i64,
    ) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.fail(receipt_id, max_attempts, backoff_ms),
            Self::Sqlite(store) => store.fail(receipt_id, max_attempts, backoff_ms),
        }
    }

    pub(in crate::engine) fn fail_with_attempt(
        &mut self,
        receipt_id: &str,
        max_attempts: u32,
        backoff_ms: i64,
        attempt: EngineQueueAttemptRecord,
    ) -> Result<bool> {
        match self {
            Self::InMemory(store) => {
                store.fail_with_attempt(receipt_id, max_attempts, backoff_ms, Some(attempt))
            }
            Self::Sqlite(store) => {
                store.fail_with_attempt(receipt_id, max_attempts, backoff_ms, Some(attempt))
            }
        }
    }

    pub(in crate::engine) fn cancel(&mut self, receipt_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.cancel(receipt_id),
            Self::Sqlite(store) => store.cancel(receipt_id),
        }
    }

    pub(in crate::engine) fn get(&self, receipt_id: &str) -> Result<Option<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.get(receipt_id),
            Self::Sqlite(store) => store.get(receipt_id),
        }
    }

    pub(in crate::engine) fn list(
        &self,
        queue: &str,
        limit: usize,
    ) -> Result<Vec<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.list(queue, limit),
            Self::Sqlite(store) => store.list(queue, limit),
        }
    }

    pub(in crate::engine) fn list_by_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.list_by_session(session_id),
            Self::Sqlite(store) => store.list_by_session(session_id),
        }
    }
}

pub(in crate::engine) enum ResourceLeaseStoreBackend {
    InMemory(InMemoryEngineResourceLeaseStore),
    Sqlite(SqliteEngineResourceLeaseStore),
}

impl ResourceLeaseStoreBackend {
    pub(in crate::engine) fn acquire(
        &mut self,
        request: AcquireResourceLease,
    ) -> Result<EngineResourceLease> {
        match self {
            Self::InMemory(store) => store.acquire(request),
            Self::Sqlite(store) => store.acquire(request),
        }
    }

    pub(in crate::engine) fn release(
        &mut self,
        lease_id: &str,
    ) -> Result<Option<EngineResourceLease>> {
        match self {
            Self::InMemory(store) => store.release(lease_id),
            Self::Sqlite(store) => store.release(lease_id),
        }
    }

    pub(in crate::engine) fn get(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        match self {
            Self::InMemory(store) => store.get(lease_id),
            Self::Sqlite(store) => store.get(lease_id),
        }
    }
}

pub(in crate::engine) enum CompensationStoreBackend {
    InMemory(InMemoryEngineCompensationStore),
    Sqlite(SqliteEngineCompensationStore),
}

impl CompensationStoreBackend {
    pub(in crate::engine) fn record(
        &mut self,
        record: EngineCompensationRecord,
    ) -> Result<EngineCompensationRecord> {
        match self {
            Self::InMemory(store) => store.record(record),
            Self::Sqlite(store) => store.record(record),
        }
    }

    pub(in crate::engine) fn get(
        &self,
        compensation_id: &str,
    ) -> Result<Option<EngineCompensationRecord>> {
        match self {
            Self::InMemory(store) => store.get(compensation_id),
            Self::Sqlite(store) => store.get(compensation_id),
        }
    }

    pub(in crate::engine) fn list(&self) -> Result<Vec<EngineCompensationRecord>> {
        match self {
            Self::InMemory(store) => store.list(),
            Self::Sqlite(store) => store.list(),
        }
    }
}

pub(in crate::engine) enum ResourceStoreBackend {
    InMemory(InMemoryEngineResourceStore),
    Sqlite(SqliteEngineResourceStore),
}

impl ResourceStoreBackend {
    pub(in crate::engine) fn register_type(
        &mut self,
        request: RegisterResourceType,
    ) -> Result<EngineResourceTypeDefinition> {
        match self {
            Self::InMemory(store) => store.register_type(request),
            Self::Sqlite(store) => store.register_type(request),
        }
    }

    pub(in crate::engine) fn create(&mut self, request: CreateResource) -> Result<EngineResource> {
        match self {
            Self::InMemory(store) => store.create(request),
            Self::Sqlite(store) => store.create(request),
        }
    }

    pub(in crate::engine) fn update(
        &mut self,
        request: UpdateResource,
    ) -> Result<EngineResourceVersion> {
        match self {
            Self::InMemory(store) => store.update(request),
            Self::Sqlite(store) => store.update(request),
        }
    }

    pub(in crate::engine) fn link(
        &mut self,
        request: LinkResources,
    ) -> Result<crate::engine::durability::resources::EngineResourceLink> {
        match self {
            Self::InMemory(store) => store.link(request),
            Self::Sqlite(store) => store.link(request),
        }
    }

    pub(in crate::engine) fn list_links_for_source(
        &self,
        source_resource_id: &str,
        relation: &str,
        limit: usize,
    ) -> Result<Vec<EngineResourceLink>> {
        match self {
            Self::InMemory(store) => {
                store.list_links_for_source(source_resource_id, relation, limit)
            }
            Self::Sqlite(store) => store.list_links_for_source(source_resource_id, relation, limit),
        }
    }

    pub(in crate::engine) fn inspect(
        &self,
        resource_id: &str,
    ) -> Result<Option<EngineResourceInspection>> {
        match self {
            Self::InMemory(store) => store.inspect(resource_id),
            Self::Sqlite(store) => store.inspect(resource_id),
        }
    }

    pub(in crate::engine) fn list(&self, filter: ListResources) -> Result<Vec<EngineResource>> {
        match self {
            Self::InMemory(store) => store.list(filter),
            Self::Sqlite(store) => store.list(filter),
        }
    }

    pub(in crate::engine) fn list_internal_scan(
        &self,
        filter: ListResources,
    ) -> Result<Vec<EngineResource>> {
        match self {
            Self::InMemory(store) => store.list_internal_scan(filter),
            Self::Sqlite(store) => store.list_internal_scan(filter),
        }
    }
}

/// Engine primitive store bundle.
#[derive(Clone)]
pub(in crate::engine) struct PrimitiveStores {
    pub(in crate::engine) streams: Arc<StdMutex<StreamStoreBackend>>,
    pub(in crate::engine) state: Arc<StdMutex<StateStoreBackend>>,
    pub(in crate::engine) queue: Arc<StdMutex<QueueStoreBackend>>,
    pub(in crate::engine) leases: Arc<StdMutex<ResourceLeaseStoreBackend>>,
    pub(in crate::engine) resources: Arc<StdMutex<ResourceStoreBackend>>,
    pub(in crate::engine) grants: Arc<StdMutex<EngineGrantStoreBackend>>,
    pub(in crate::engine) compensation: Arc<StdMutex<CompensationStoreBackend>>,
    engine_host: Arc<OnceLock<Weak<AsyncMutex<EngineHost>>>>,
}

impl PrimitiveStores {
    pub(in crate::engine) fn in_memory() -> Self {
        let stores = Self {
            streams: Arc::new(StdMutex::new(StreamStoreBackend::InMemory(
                InMemoryEngineStreamStore::new(),
            ))),
            state: Arc::new(StdMutex::new(StateStoreBackend::InMemory(
                InMemoryEngineStateStore::new(),
            ))),
            queue: Arc::new(StdMutex::new(QueueStoreBackend::InMemory(
                InMemoryEngineQueueStore::new(),
            ))),
            leases: Arc::new(StdMutex::new(ResourceLeaseStoreBackend::InMemory(
                InMemoryEngineResourceLeaseStore::new(),
            ))),
            resources: Arc::new(StdMutex::new(ResourceStoreBackend::InMemory(
                InMemoryEngineResourceStore::new(),
            ))),
            grants: Arc::new(StdMutex::new(EngineGrantStoreBackend::InMemory(
                InMemoryEngineGrantStore::new(),
            ))),
            compensation: Arc::new(StdMutex::new(CompensationStoreBackend::InMemory(
                InMemoryEngineCompensationStore::new(),
            ))),
            engine_host: Arc::new(OnceLock::new()),
        };
        stores
            .install_builtin_resource_types()
            .expect("built-in resource type definitions are valid");
        stores
    }

    pub(in crate::engine) fn sqlite(path: &std::path::Path) -> Result<Self> {
        let stores = Self {
            streams: Arc::new(StdMutex::new(StreamStoreBackend::Sqlite(
                SqliteEngineStreamStore::open(path)?,
            ))),
            state: Arc::new(StdMutex::new(StateStoreBackend::Sqlite(
                SqliteEngineStateStore::open(path)?,
            ))),
            queue: Arc::new(StdMutex::new(QueueStoreBackend::Sqlite(
                SqliteEngineQueueStore::open(path)?,
            ))),
            leases: Arc::new(StdMutex::new(ResourceLeaseStoreBackend::Sqlite(
                SqliteEngineResourceLeaseStore::open(path)?,
            ))),
            resources: Arc::new(StdMutex::new(ResourceStoreBackend::Sqlite(
                SqliteEngineResourceStore::open(path)?,
            ))),
            grants: Arc::new(StdMutex::new(EngineGrantStoreBackend::Sqlite(
                SqliteEngineGrantStore::open(path)?,
            ))),
            compensation: Arc::new(StdMutex::new(CompensationStoreBackend::Sqlite(
                SqliteEngineCompensationStore::open(path)?,
            ))),
            engine_host: Arc::new(OnceLock::new()),
        };
        stores.install_builtin_resource_types()?;
        Ok(stores)
    }

    pub(in crate::engine) fn install_engine_host(
        &self,
        handle: Weak<AsyncMutex<EngineHost>>,
    ) -> Result<()> {
        self.engine_host.set(handle).map_err(|_| {
            EngineError::PolicyViolation(
                "primitive engine host handle already installed".to_owned(),
            )
        })
    }

    pub(in crate::engine) fn engine_host(&self) -> Result<EngineHostHandle> {
        let weak = self.engine_host.get().ok_or_else(|| {
            EngineError::PolicyViolation(
                "primitive engine host handle is unavailable during async primitive execution"
                    .to_owned(),
            )
        })?;
        let inner = weak.upgrade().ok_or_else(|| {
            EngineError::PolicyViolation("primitive engine host handle was dropped".to_owned())
        })?;
        Ok(EngineHostHandle::from_inner(inner))
    }

    fn install_builtin_resource_types(&self) -> Result<()> {
        let mut resources = self
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?;
        for definition in builtin_resource_type_definitions() {
            resources.register_type(definition)?;
        }
        for resource in builtin_module_manifest_resources() {
            let Some(resource_id) = resource.resource_id.clone() else {
                continue;
            };
            if resources.inspect(&resource_id)?.is_none() {
                resources.create(resource)?;
            }
        }
        Ok(())
    }
}
