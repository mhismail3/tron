//! Engine-owned primitive workers.
//!
//! Primitive workers are built into the engine, but they still follow the same
//! worker/function contract shape as domain workers. The host coordinates
//! locking and ledger completion; this module owns primitive worker definitions,
//! schemas, handler bindings, and privileged query response shaping through the
//! local `runtime` module.
//! `grant::*` is the engine-owned authority surface; `resource::*` plus the
//! artifact/goal/claim/evidence/decision wrappers form the durable output
//! substrate. Materialized-file wrappers keep file bytes tied to resource
//! versions, record damaged truth through the resource store, and block
//! operational reads or rewrites after discard while leaving inspection
//! available. `trigger::*` dispatches registered triggers back through the
//! same trigger runtime used by transports and schedules, so queued trigger
//! delivery is not a harness-only path. `ui::*` stores fixed-catalog generated
//! UI as `ui_surface` resources, authors deterministic target surfaces from
//! substrate projections, validates/refreshes/expires generated versions, and
//! routes submitted actions back through canonical capability invocations.
//! Stored-surface/action
//! validation is owned by the UI primitive's validation submodule so authoring
//! and execution checks do not blur together. Operator action summaries and
//! consequence projections are shaped by the local `action_summary` helper so
//! control, module, trust-audit, and generated UI surfaces do not drift.
//! `module::*` registers,
//! configures, activates, disables, upgrades, rolls back, and quarantines
//! worker packages as typed resources under derived grants, with trust-root
//! renewal, key-rotation evidence, expiry, explicit revocation enforcement,
//! trust-change simulation, trust-review evidence, and scheduled trust audits
//! represented as decision/evidence resources. Trust-audit status, retention
//! review, and activation runtime cleanup diagnostics stay projection/evidence
//! only. The module primitive keeps source-trust, health/integrity,
//! activation-runtime, trust-review, and scheduled-audit ownership in focused
//! submodules so the parent registration surface does not become another policy
//! plane.
//! `storage::*` is the
//! system primitive surface for the unified
//! `tron.sqlite` runtime: stats, retention, checkpoints, and portable snapshot
//! export.

use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};

use serde_json::{Value, json};
use tokio::sync::Mutex as AsyncMutex;

use super::approval::{
    ApprovalDecision, ApprovalStatus, EngineApprovalRecord, EngineApprovalRequest,
    EngineApprovalRequestOutcome, InMemoryEngineApprovalStore, SqliteEngineApprovalStore,
};
use super::compensation::{
    EngineCompensationRecord, InMemoryEngineCompensationStore, SqliteEngineCompensationStore,
};
use super::errors::{EngineError, Result};
use super::grants::{EngineGrantStoreBackend, InMemoryEngineGrantStore, SqliteEngineGrantStore};
use super::host::{EngineHost, EngineHostHandle};
use super::ids::{ActorId, AuthorityGrantId, FunctionId, WorkerId};
use super::invocation::{InProcessFunctionHandler, Invocation};
use super::leases::{
    AcquireResourceLease, EngineResourceLease, InMemoryEngineResourceLeaseStore,
    SqliteEngineResourceLeaseStore,
};
use super::queue::{
    EngineQueueItem, EnqueueInvocation, InMemoryEngineQueueStore, SqliteEngineQueueStore,
};
use super::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceTypeDefinition,
    EngineResourceVersion, InMemoryEngineResourceStore, LinkResources, ListResources,
    RegisterResourceType, SqliteEngineResourceStore, UpdateResource,
    builtin_resource_type_definitions,
};
use super::state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
use super::streams::{
    EngineStreamPage, EngineStreamSubscription, InMemoryEngineStreamStore, PublishStreamEvent,
    SqliteEngineStreamStore, StreamActorScope, StreamCursor,
};
use super::types::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    RiskLevel, VisibilityScope, WorkerDefinition, WorkerKind,
};

pub(crate) mod action_summary;
pub(crate) mod approval;
pub(crate) mod catalog;
pub(crate) mod control;
pub(crate) mod grant;
pub(crate) mod module;
pub(crate) mod observability;
pub(crate) mod queue;
pub(crate) mod resource;
pub(in crate::engine) mod runtime;
pub(crate) mod state;
pub(crate) mod storage;
pub(crate) mod stream;
pub(crate) mod trigger;
pub(crate) mod ui;
pub(crate) mod worker;

pub(crate) const STREAM_WORKER_ID: &str = "stream";
pub(crate) const STATE_WORKER_ID: &str = "state";
pub(crate) const QUEUE_WORKER_ID: &str = "queue";
pub(crate) const RESOURCE_WORKER_ID: &str = "resource";
pub(crate) const TRIGGER_WORKER_ID: &str = "trigger";
pub(crate) const GRANT_WORKER_ID: &str = "grant";
pub(crate) const APPROVAL_WORKER_ID: &str = "approval";
pub(crate) const CATALOG_WORKER_ID: &str = "catalog";
pub(crate) const CONTROL_WORKER_ID: &str = "control";
pub(crate) const WORKER_WORKER_ID: &str = "worker";
pub(crate) const OBSERVABILITY_WORKER_ID: &str = "observability";
pub(crate) const STORAGE_WORKER_ID: &str = "storage";
pub(crate) const UI_WORKER_ID: &str = "ui";
pub(crate) const MODULE_WORKER_ID: &str = "module";
const ENGINE_OWNER_ACTOR: &str = "system";
const ENGINE_AUTHORITY_GRANT: &str = "engine-system";

pub(crate) const APPROVAL_REQUEST_FUNCTION: &str = "approval::request";
pub(crate) const APPROVAL_RESOLVE_FUNCTION: &str = "approval::resolve";
pub(crate) const APPROVAL_GET_FUNCTION: &str = "approval::get";
pub(crate) const APPROVAL_LIST_FUNCTION: &str = "approval::list";

/// One primitive function registration.
pub(crate) struct PrimitiveFunctionRegistration {
    /// Function contract.
    pub definition: FunctionDefinition,
    /// In-process handler. Host-dispatched primitives use `None`.
    pub handler: Option<Arc<dyn InProcessFunctionHandler>>,
}

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

    pub(in crate::engine) fn list_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<super::streams::EngineStreamEvent>> {
        match self {
            Self::InMemory(store) => store.list_by_trace(trace_id, limit),
            Self::Sqlite(store) => store.list_by_trace(trace_id, limit),
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
}

pub(in crate::engine) enum ApprovalStoreBackend {
    InMemory(InMemoryEngineApprovalStore),
    Sqlite(SqliteEngineApprovalStore),
}

impl ApprovalStoreBackend {
    pub(in crate::engine) fn request(
        &mut self,
        request: EngineApprovalRequest,
    ) -> Result<EngineApprovalRequestOutcome> {
        match self {
            Self::InMemory(store) => store.request(request),
            Self::Sqlite(store) => store.request(request),
        }
    }

    pub(in crate::engine) fn get(&self, approval_id: &str) -> Result<Option<EngineApprovalRecord>> {
        match self {
            Self::InMemory(store) => store.get(approval_id),
            Self::Sqlite(store) => store.get(approval_id),
        }
    }

    pub(in crate::engine) fn list(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        match self {
            Self::InMemory(store) => store.list(status, session_id, limit),
            Self::Sqlite(store) => store.list(status, session_id, limit),
        }
    }

    pub(in crate::engine) fn resolve(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
        actor_id: ActorId,
    ) -> Result<EngineApprovalRecord> {
        match self {
            Self::InMemory(store) => store.resolve(approval_id, decision, actor_id),
            Self::Sqlite(store) => store.resolve(approval_id, decision, actor_id),
        }
    }

    pub(in crate::engine) fn complete(
        &mut self,
        approval_id: &str,
        result: &super::invocation::InvocationResult,
    ) -> Result<EngineApprovalRecord> {
        match self {
            Self::InMemory(store) => store.complete(approval_id, result),
            Self::Sqlite(store) => store.complete(approval_id, result),
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

    pub(in crate::engine) fn list_by_trace(
        &self,
        trace_id: &str,
        limit: usize,
    ) -> Result<Vec<EngineResourceLease>> {
        match self {
            Self::InMemory(store) => store.list_by_trace(trace_id, limit),
            Self::Sqlite(store) => store.list_by_trace(trace_id, limit),
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

    pub(in crate::engine) fn list_types(&self) -> Result<Vec<EngineResourceTypeDefinition>> {
        match self {
            Self::InMemory(store) => store.list_types(),
            Self::Sqlite(store) => store.list_types(),
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
    ) -> Result<super::resources::EngineResourceLink> {
        match self {
            Self::InMemory(store) => store.link(request),
            Self::Sqlite(store) => store.link(request),
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
}

/// Engine primitive store bundle.
#[derive(Clone)]
pub(in crate::engine) struct PrimitiveStores {
    pub(in crate::engine) streams: Arc<StdMutex<StreamStoreBackend>>,
    pub(in crate::engine) state: Arc<StdMutex<StateStoreBackend>>,
    pub(in crate::engine) queue: Arc<StdMutex<QueueStoreBackend>>,
    pub(in crate::engine) approvals: Arc<StdMutex<ApprovalStoreBackend>>,
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
            approvals: Arc::new(StdMutex::new(ApprovalStoreBackend::InMemory(
                InMemoryEngineApprovalStore::new(),
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
            approvals: Arc::new(StdMutex::new(ApprovalStoreBackend::Sqlite(
                SqliteEngineApprovalStore::open(path)?,
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
        Ok(())
    }
}

pub(in crate::engine) fn primitive_workers() -> Result<Vec<WorkerDefinition>> {
    let resource_worker = primitive_worker(RESOURCE_WORKER_ID, WorkerKind::System)?
        .with_namespace_claim("artifact")
        .with_namespace_claim("goal")
        .with_namespace_claim("claim")
        .with_namespace_claim("evidence")
        .with_namespace_claim("decision")
        .with_namespace_claim("worker_package")
        .with_namespace_claim("module_config")
        .with_namespace_claim("activation_record")
        .with_namespace_claim("harness_doc")
        .with_namespace_claim("materialized_file")
        .with_namespace_claim("patch");
    Ok(vec![
        primitive_worker(STREAM_WORKER_ID, WorkerKind::Stream)?,
        primitive_worker(STATE_WORKER_ID, WorkerKind::State)?,
        primitive_worker(QUEUE_WORKER_ID, WorkerKind::Queue)?,
        resource_worker,
        primitive_worker(TRIGGER_WORKER_ID, WorkerKind::System)?,
        primitive_worker(GRANT_WORKER_ID, WorkerKind::System)?,
        primitive_worker(APPROVAL_WORKER_ID, WorkerKind::System)?,
        primitive_worker(CATALOG_WORKER_ID, WorkerKind::System)?,
        primitive_worker(CONTROL_WORKER_ID, WorkerKind::System)?,
        primitive_worker(UI_WORKER_ID, WorkerKind::System)?,
        primitive_worker(MODULE_WORKER_ID, WorkerKind::System)?,
        primitive_worker(WORKER_WORKER_ID, WorkerKind::System)?,
        primitive_worker(OBSERVABILITY_WORKER_ID, WorkerKind::System)?,
        primitive_worker(STORAGE_WORKER_ID, WorkerKind::System)?,
    ])
}

pub(in crate::engine) fn primitive_function_definitions(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let mut registrations = Vec::new();
    registrations.extend(stream::registrations(stores)?);
    registrations.extend(state::registrations(stores)?);
    registrations.extend(queue::registrations(stores)?);
    registrations.extend(resource::registrations(stores)?);
    registrations.extend(trigger::registrations(stores)?);
    registrations.extend(grant::registrations(stores)?);
    registrations.extend(approval::registrations(stores)?);
    registrations.extend(catalog::registrations()?);
    registrations.extend(control::registrations()?);
    registrations.extend(ui::registrations()?);
    registrations.extend(module::registrations(stores)?);
    registrations.extend(worker::registrations()?);
    registrations.extend(observability::registrations()?);
    registrations.extend(storage::registrations()?);
    Ok(registrations)
}

fn primitive_worker(id: &str, kind: WorkerKind) -> Result<WorkerDefinition> {
    Ok(WorkerDefinition::new(
        worker_id(id)?,
        kind,
        actor_id(ENGINE_OWNER_ACTOR)?,
        grant_id(ENGINE_AUTHORITY_GRANT)?,
    )
    .with_namespace_claim(id))
}

pub(super) fn primitive_function(
    id: &str,
    worker: &str,
    description: &str,
    effect: EffectClass,
    authority_scope: &str,
) -> FunctionDefinition {
    FunctionDefinition::new(
        function_id(id).expect("valid static primitive function id"),
        worker_id(worker).expect("valid static primitive worker id"),
        description,
        VisibilityScope::Agent,
        effect,
    )
    .with_required_authority(AuthorityRequirement::scope(authority_scope))
    .with_risk(if effect.is_mutating() {
        RiskLevel::Medium
    } else {
        RiskLevel::Low
    })
}

pub(super) fn host_dispatched_registration(
    definition: FunctionDefinition,
) -> PrimitiveFunctionRegistration {
    PrimitiveFunctionRegistration {
        definition,
        handler: None,
    }
}

pub(super) fn handled_registration(
    definition: FunctionDefinition,
    handler: Arc<dyn InProcessFunctionHandler>,
) -> PrimitiveFunctionRegistration {
    PrimitiveFunctionRegistration {
        definition,
        handler: Some(handler),
    }
}

pub(in crate::engine) fn approval_request_from_invocation(
    invocation: &Invocation,
) -> Result<EngineApprovalRequest> {
    let function_id = function_id(required_str(&invocation.payload, "functionId")?)?;
    let payload = invocation
        .payload
        .get("payload")
        .cloned()
        .unwrap_or(Value::Null);
    Ok(EngineApprovalRequest {
        function_id,
        payload,
        causal_context: invocation.causal_context.clone(),
        delivery_mode: invocation.delivery_mode,
    })
}

pub(super) fn state_scope_from_payload(invocation: &Invocation) -> Result<EngineStateScope> {
    match optional_string(invocation.payload.get("scope"))?
        .unwrap_or_else(|| "session".to_owned())
        .as_str()
    {
        "system" => Ok(EngineStateScope::System),
        "workspace" => {
            let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                .or(invocation.causal_context.workspace_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "workspace-scoped state requires workspaceId".to_owned(),
                    )
                })?;
            Ok(EngineStateScope::Workspace(workspace_id))
        }
        "session" => {
            let session_id = optional_string(invocation.payload.get("sessionId"))?
                .or(invocation.causal_context.session_id.clone())
                .ok_or_else(|| {
                    EngineError::PolicyViolation(
                        "session-scoped state requires sessionId".to_owned(),
                    )
                })?;
            Ok(EngineStateScope::Session(session_id))
        }
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported state scope {other}"
        ))),
    }
}

pub(super) fn required_string_owned(payload: &Value, field: &str) -> Result<String> {
    Ok(required_str(payload, field)?.to_owned())
}

pub(in crate::engine) fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(in crate::engine) fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    value
        .map(|value| {
            value.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be a string".to_owned())
            })
        })
        .transpose()
}

pub(in crate::engine) fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    value
        .map(|value| {
            value.as_u64().ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be an integer".to_owned())
            })
        })
        .transpose()
}

pub(super) fn parse_approval_status(value: &str) -> Result<ApprovalStatus> {
    match value {
        "pending" => Ok(ApprovalStatus::Pending),
        "approved" => Ok(ApprovalStatus::Approved),
        "denied" => Ok(ApprovalStatus::Denied),
        "executed" => Ok(ApprovalStatus::Executed),
        "failed" => Ok(ApprovalStatus::Failed),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported approval status {other}"
        ))),
    }
}

pub(super) fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("visibility must be a string".to_owned())
                })
                .and_then(parse_visibility)
        })
        .transpose()
}

pub(super) fn parse_visibility(value: &str) -> Result<VisibilityScope> {
    match value {
        "internal" => Ok(VisibilityScope::Internal),
        "session" => Ok(VisibilityScope::Session),
        "workspace" => Ok(VisibilityScope::Workspace),
        "system" => Ok(VisibilityScope::System),
        "client" => Ok(VisibilityScope::Client),
        "worker" => Ok(VisibilityScope::Worker),
        "agent" => Ok(VisibilityScope::Agent),
        "admin" => Ok(VisibilityScope::Admin),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported visibility {value}"
        ))),
    }
}

pub(super) fn function_id(value: &str) -> Result<FunctionId> {
    FunctionId::new(value)
}

pub(super) fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value)
}

fn actor_id(value: &str) -> Result<ActorId> {
    ActorId::new(value)
}

fn grant_id(value: &str) -> Result<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}

pub(super) fn boolean_response_schema(field: &str) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(field.to_owned(), json!({"type": "boolean"}));
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": properties
    })
}

pub(super) fn nullable_response_schema(field: &str) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(field.to_owned(), json!({}));
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": properties
    })
}

pub(super) fn primitive_compensation(
    kind: CompensationKind,
    notes: &'static str,
) -> CompensationContract {
    CompensationContract::new(kind, notes)
}
