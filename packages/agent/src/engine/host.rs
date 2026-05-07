//! Agent-facing engine host and privileged meta-capabilities.
//!
//! `EngineHost` is the boundary future server/runtime adapters should use when
//! they need the live capability fabric. It keeps `engine::*` capabilities
//! visible as normal catalog functions while executing them through privileged
//! host code that cannot be replaced by ordinary workers.

use std::any::Any;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};

use async_trait::async_trait;
use futures::FutureExt as _;
use serde_json::{Value, json};
use tokio::sync::{Mutex, MutexGuard};

use super::approval::{
    ApprovalDecision, ApprovalStatus, EngineApprovalRecord, EngineApprovalRequest,
    InMemoryEngineApprovalStore, SqliteEngineApprovalStore,
};
use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
use super::invocation::{CausalContext, InProcessFunctionHandler, Invocation, InvocationResult};
use super::ledger::{
    EngineLedgerStore, IdempotencyReservation, SqliteEngineLedgerStore, StoredEngineError,
};
use super::queue::{
    EngineQueueItem, EnqueueInvocation, InMemoryEngineQueueStore, SqliteEngineQueueStore,
};
use super::registry::{InvocationIdempotencyDecision, LiveCatalog, PreparedSyncInvocationDecision};
use super::state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
use super::streams::{
    EngineStreamPage, EngineStreamSubscription, InMemoryEngineStreamStore, PublishStreamEvent,
    SqliteEngineStreamStore, StreamActorScope, StreamCursor,
};
use super::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    DeliveryMode, EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision,
    IdempotencyContract, Provenance, RiskLevel, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind, WorkerRevision,
};
use super::{policy, schema};

const ENGINE_WORKER_ID: &str = "engine";
const ENGINE_OWNER_ACTOR: &str = "system";
const ENGINE_AUTHORITY_GRANT: &str = "engine-system";

const DISCOVER_FUNCTION: &str = "engine::discover";
const INSPECT_FUNCTION: &str = "engine::inspect";
const WATCH_FUNCTION: &str = "engine::watch";
const INVOKE_FUNCTION: &str = "engine::invoke";
const PROMOTE_FUNCTION: &str = "engine::promote";

const WATCH_DEFAULT_LIMIT: usize = 100;
const WATCH_MAX_LIMIT: usize = 500;

const STREAM_WORKER_ID: &str = "stream";
const STATE_WORKER_ID: &str = "state";
const QUEUE_WORKER_ID: &str = "queue";
const APPROVAL_WORKER_ID: &str = "approval";

const APPROVAL_REQUEST_FUNCTION: &str = "approval::request";
const APPROVAL_RESOLVE_FUNCTION: &str = "approval::resolve";
const APPROVAL_GET_FUNCTION: &str = "approval::get";
const APPROVAL_LIST_FUNCTION: &str = "approval::list";

struct PreparedDelegatedInvocation {
    meta_invocation: Invocation,
    meta_function: FunctionDefinition,
    child: PreparedSyncInvocationDecision,
}

enum PreparedDelegatedInvocationDecision {
    Execute(Box<PreparedDelegatedInvocation>),
    Finished(Box<InvocationResult>),
}

enum StreamStoreBackend {
    InMemory(InMemoryEngineStreamStore),
    Sqlite(SqliteEngineStreamStore),
}

impl StreamStoreBackend {
    fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        match self {
            Self::InMemory(store) => store.publish(event),
            Self::Sqlite(store) => store.publish(event),
        }
    }

    fn subscribe(
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

    fn unsubscribe(&mut self, subscription_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.unsubscribe(subscription_id),
            Self::Sqlite(store) => store.unsubscribe(subscription_id),
        }
    }

    fn poll(
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
}

enum StateStoreBackend {
    InMemory(InMemoryEngineStateStore),
    Sqlite(SqliteEngineStateStore),
}

impl StateStoreBackend {
    fn get(
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

    fn set(
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

    fn compare_and_set(
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

    fn delete(&mut self, scope: EngineStateScope, namespace: &str, key: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.delete(scope, namespace, key),
            Self::Sqlite(store) => store.delete(scope, namespace, key),
        }
    }

    fn list(
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

enum QueueStoreBackend {
    InMemory(InMemoryEngineQueueStore),
    Sqlite(SqliteEngineQueueStore),
}

impl QueueStoreBackend {
    fn enqueue(&mut self, request: EnqueueInvocation) -> Result<EngineQueueItem> {
        match self {
            Self::InMemory(store) => store.enqueue(request),
            Self::Sqlite(store) => store.enqueue(request),
        }
    }

    fn claim(
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

    fn claim_by_receipt(
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

    fn complete(&mut self, receipt_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.complete(receipt_id),
            Self::Sqlite(store) => store.complete(receipt_id),
        }
    }

    fn fail(&mut self, receipt_id: &str, max_attempts: u32, backoff_ms: i64) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.fail(receipt_id, max_attempts, backoff_ms),
            Self::Sqlite(store) => store.fail(receipt_id, max_attempts, backoff_ms),
        }
    }

    fn cancel(&mut self, receipt_id: &str) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.cancel(receipt_id),
            Self::Sqlite(store) => store.cancel(receipt_id),
        }
    }

    fn get(&self, receipt_id: &str) -> Result<Option<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.get(receipt_id),
            Self::Sqlite(store) => store.get(receipt_id),
        }
    }

    fn list(&self, queue: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        match self {
            Self::InMemory(store) => store.list(queue, limit),
            Self::Sqlite(store) => store.list(queue, limit),
        }
    }
}

enum ApprovalStoreBackend {
    InMemory(InMemoryEngineApprovalStore),
    Sqlite(SqliteEngineApprovalStore),
}

impl ApprovalStoreBackend {
    fn request(&mut self, request: EngineApprovalRequest) -> Result<EngineApprovalRecord> {
        match self {
            Self::InMemory(store) => store.request(request),
            Self::Sqlite(store) => store.request(request),
        }
    }

    fn get(&self, approval_id: &str) -> Result<Option<EngineApprovalRecord>> {
        match self {
            Self::InMemory(store) => store.get(approval_id),
            Self::Sqlite(store) => store.get(approval_id),
        }
    }

    fn list(
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

    fn resolve(
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

    fn complete(
        &mut self,
        approval_id: &str,
        result: &InvocationResult,
    ) -> Result<EngineApprovalRecord> {
        match self {
            Self::InMemory(store) => store.complete(approval_id, result),
            Self::Sqlite(store) => store.complete(approval_id, result),
        }
    }
}

#[derive(Clone)]
struct PrimitiveStores {
    streams: Arc<StdMutex<StreamStoreBackend>>,
    state: Arc<StdMutex<StateStoreBackend>>,
    queue: Arc<StdMutex<QueueStoreBackend>>,
    approvals: Arc<StdMutex<ApprovalStoreBackend>>,
}

impl PrimitiveStores {
    fn in_memory() -> Self {
        Self {
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
        }
    }

    fn sqlite(path: &Path) -> Result<Self> {
        Ok(Self {
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
        })
    }
}

/// Host for the in-process live capability engine.
pub struct EngineHost {
    catalog: LiveCatalog,
    primitives: PrimitiveStores,
}

/// Cloneable owner for the live capability engine host.
#[derive(Clone)]
pub struct EngineHostHandle {
    inner: Arc<Mutex<EngineHost>>,
}

impl EngineHostHandle {
    /// Create an in-memory engine host for tests and isolated adapters.
    pub fn new_in_memory() -> Result<Self> {
        Ok(Self::from_host(EngineHost::new()?))
    }

    /// Open a SQLite-backed engine host.
    pub fn open_sqlite(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self::from_host(EngineHost::open_sqlite(path)?))
    }

    /// Wrap an initialized host.
    #[must_use]
    fn from_host(host: EngineHost) -> Self {
        Self {
            inner: Arc::new(Mutex::new(host)),
        }
    }

    /// Register or update a worker through the host boundary.
    pub async fn register_worker(
        &self,
        definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_worker(definition, volatile)
    }

    /// Unregister a worker and clean up its volatile owned entries.
    pub async fn unregister_worker(&self, id: &WorkerId, owner_actor: &str) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_worker(id, owner_actor)
    }

    /// Register or update a worker during single-threaded startup/test setup.
    ///
    /// This fails closed if the host is already in use, keeping setup code from
    /// blocking on a global engine mutex.
    pub fn register_worker_for_setup(
        &self,
        definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during worker setup".to_owned())
            })?
            .catalog
            .register_worker(definition, volatile)
    }

    /// Register or update a function through the host boundary.
    pub async fn register_function(
        &self,
        definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_function(definition, handler, volatile)
    }

    /// Register or update a function during single-threaded startup/test setup.
    ///
    /// This is the synchronous counterpart to [`Self::register_function`] for
    /// builders that assemble a full server context before any async work has
    /// started.
    pub fn register_function_for_setup(
        &self,
        definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during function setup".to_owned())
            })?
            .catalog
            .register_function(definition, handler, volatile)
    }

    /// Unregister a function through the host boundary.
    pub async fn unregister_function(&self, id: &FunctionId, owner: &WorkerId) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_function(id, owner)
    }

    /// Register or update a trigger type through the host boundary.
    pub async fn register_trigger_type(
        &self,
        definition: TriggerTypeDefinition,
        volatile: bool,
    ) -> Result<()> {
        self.inner
            .lock()
            .await
            .catalog
            .register_trigger_type(definition, volatile)
    }

    /// Register or update a trigger type during single-threaded setup.
    pub fn register_trigger_type_for_setup(
        &self,
        definition: TriggerTypeDefinition,
        volatile: bool,
    ) -> Result<()> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation(
                    "engine host is busy during trigger-type setup".to_owned(),
                )
            })?
            .catalog
            .register_trigger_type(definition, volatile)
    }

    /// Register or update a trigger through the host boundary.
    pub async fn register_trigger(
        &self,
        definition: TriggerDefinition,
        volatile: bool,
    ) -> Result<super::types::TriggerRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .register_trigger(definition, volatile)
    }

    /// Register or update a trigger during single-threaded setup.
    pub fn register_trigger_for_setup(
        &self,
        definition: TriggerDefinition,
        volatile: bool,
    ) -> Result<super::types::TriggerRevision> {
        self.inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation("engine host is busy during trigger setup".to_owned())
            })?
            .catalog
            .register_trigger(definition, volatile)
    }

    /// Unregister a trigger through the host boundary.
    pub async fn unregister_trigger(
        &self,
        id: &TriggerId,
        owner_worker: &WorkerId,
    ) -> Result<bool> {
        self.inner
            .lock()
            .await
            .catalog
            .unregister_trigger(id, owner_worker)
    }

    /// Discover visible functions through the host boundary.
    pub async fn discover(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.inner.lock().await.catalog.discover_functions(query)
    }

    /// Inspect a visible function through the host boundary.
    pub async fn inspect_function(
        &self,
        id: &FunctionId,
        actor: Option<&ActorContext>,
    ) -> Result<FunctionDefinition> {
        self.inner.lock().await.catalog.inspect_function(id, actor)
    }

    /// Inspect a worker through the host boundary.
    pub async fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition> {
        self.inner.lock().await.catalog.inspect_worker(id)
    }

    /// Inspect a trigger through the host boundary.
    pub async fn inspect_trigger(&self, id: &TriggerId) -> Result<TriggerDefinition> {
        self.inner.lock().await.catalog.inspect_trigger(id)
    }

    /// Inspect a trigger type through the host boundary.
    pub async fn inspect_trigger_type(&self, id: &TriggerTypeId) -> Result<TriggerTypeDefinition> {
        self.inner.lock().await.catalog.inspect_trigger_type(id)
    }

    /// Watch catalog changes through the host boundary.
    pub async fn watch(
        &self,
        actor: &ActorContext,
        request: EngineWatchRequest,
    ) -> Result<EngineWatchResponse> {
        self.inner.lock().await.watch_catalog(actor, request)
    }

    /// Promote function visibility through the host boundary.
    pub async fn promote_function_visibility(
        &self,
        id: &FunctionId,
        owner: &WorkerId,
        target: VisibilityScope,
        workspace_id: Option<String>,
    ) -> Result<FunctionRevision> {
        self.inner
            .lock()
            .await
            .catalog
            .promote_function_visibility(id, owner, target, workspace_id)
    }

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
        if invocation.function_id.namespace() == ENGINE_WORKER_ID {
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

        let handler_result = AssertUnwindSafe(prepared.handler.invoke(prepared.invocation.clone()))
            .catch_unwind()
            .await
            .unwrap_or_else(|payload| {
                Err(EngineError::HandlerFailed(format!(
                    "handler panicked: {}",
                    panic_payload_message(payload)
                )))
            });

        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(*prepared, handler_result)
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
        prepared: super::registry::PreparedSyncInvocation,
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
        let handler_result = AssertUnwindSafe(prepared.handler.invoke(prepared.invocation.clone()))
            .catch_unwind()
            .await
            .unwrap_or_else(|payload| {
                Err(EngineError::HandlerFailed(format!(
                    "handler panicked: {}",
                    panic_payload_message(payload)
                )))
            });
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(*prepared, handler_result)
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

    /// Create or replay an approval request and publish a pending approval
    /// stream event.
    pub async fn request_approval(
        &self,
        request: EngineApprovalRequest,
    ) -> Result<EngineApprovalRecord> {
        let store = self.inner.lock().await.primitives.approvals.clone();
        let record = store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .request(request)?;
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
            PreparedSyncInvocationDecision::Execute(child) => {
                let handler_result =
                    AssertUnwindSafe(child.handler.invoke(child.invocation.clone()))
                        .catch_unwind()
                        .await
                        .unwrap_or_else(|payload| {
                            Err(EngineError::HandlerFailed(format!(
                                "handler panicked: {}",
                                panic_payload_message(payload)
                            )))
                        });
                self.inner
                    .lock()
                    .await
                    .catalog
                    .finish_prepared_sync_invocation(*child, handler_result)
            }
            PreparedSyncInvocationDecision::Finished(result) => *result,
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

    async fn invoke_approval_resolve_unlocked(&self, invocation: Invocation) -> InvocationResult {
        let prepared = {
            let mut host = self.inner.lock().await;
            host.catalog.prepare_sync_invocation(invocation)
        };
        let prepared = match prepared {
            PreparedSyncInvocationDecision::Execute(prepared) => prepared,
            PreparedSyncInvocationDecision::Finished(result) => return *result,
        };

        let approval_id = match required_str(&prepared.invocation.payload, "approvalId") {
            Ok(value) => value.to_owned(),
            Err(error) => {
                return self
                    .finish_prepared_approval_resolve(*prepared, Err(error))
                    .await;
            }
        };
        let decision = match required_str(&prepared.invocation.payload, "decision")
            .and_then(parse_approval_decision)
        {
            Ok(decision) => decision,
            Err(error) => {
                return self
                    .finish_prepared_approval_resolve(*prepared, Err(error))
                    .await;
            }
        };
        if !can_resolve_approval(&prepared.invocation.causal_context.actor_kind) {
            return self
                .finish_prepared_approval_resolve(
                    *prepared,
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
                    .finish_prepared_approval_resolve(*prepared, Err(error))
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
                        .finish_prepared_approval_resolve(*prepared, Err(error))
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
            *prepared,
            Ok(json!({
                "approval": resolved,
                "child": child_result.map(|result| invocation_result_value(&result)),
            })),
        )
        .await
    }

    async fn finish_prepared_approval_resolve(
        &self,
        prepared: super::registry::PreparedSyncInvocation,
        result: Result<Value>,
    ) -> InvocationResult {
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(prepared, result)
    }

    /// Lock the host for deep test inspection or narrow migration setup.
    ///
    /// Production invocation/discovery paths should use the intent-shaped
    /// methods on this handle so they do not hold the host mutex across handler
    /// execution.
    pub async fn lock(&self) -> MutexGuard<'_, EngineHost> {
        self.inner.lock().await
    }
}

/// Engine ledger path colocated with the resolved event database.
#[must_use]
pub fn engine_ledger_path_for_event_db(event_db_path: &Path) -> PathBuf {
    event_db_path.parent().map_or_else(
        || PathBuf::from("engine-ledger.sqlite"),
        |parent| parent.join("engine-ledger.sqlite"),
    )
}

fn panic_payload_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&'static str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_owned()
    }
}

fn can_resolve_approval(actor_kind: &ActorKind) -> bool {
    actor_kind.is_admin_like() || matches!(actor_kind, ActorKind::User)
}

/// Cursor-pull request for catalog changes.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineWatchRequest {
    /// Return changes after this catalog revision.
    pub after_revision: CatalogRevision,
    /// Maximum number of visible matching changes to return.
    pub limit: usize,
    /// Optional change-class filter.
    pub classes: Option<Vec<CatalogChangeClass>>,
    /// Optional exact change-kind filter.
    pub kinds: Option<Vec<CatalogChangeKind>>,
    /// Optional subject id prefix.
    pub subject_prefix: Option<String>,
    /// Optional owner worker filter.
    pub owner_worker: Option<WorkerId>,
}

impl Default for EngineWatchRequest {
    fn default() -> Self {
        Self {
            after_revision: CatalogRevision(0),
            limit: WATCH_DEFAULT_LIMIT,
            classes: None,
            kinds: None,
            subject_prefix: None,
            owner_worker: None,
        }
    }
}

/// Cursor-pull response for catalog changes.
#[derive(Clone, Debug, PartialEq)]
pub struct EngineWatchResponse {
    /// Visible matching changes.
    pub changes: Vec<CatalogChange>,
    /// Current live catalog revision.
    pub current_revision: CatalogRevision,
    /// Cursor to use for the next request.
    pub next_revision: CatalogRevision,
    /// Whether more visible matching changes remain after this page.
    pub has_more: bool,
}

impl EngineHost {
    /// Create a host with an in-memory engine ledger.
    pub fn new() -> Result<Self> {
        Self::from_catalog_and_primitives(LiveCatalog::new(), PrimitiveStores::in_memory())
    }

    /// Create a host with a caller-supplied ledger.
    pub fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Result<Self> {
        Self::from_catalog_and_primitives(
            LiveCatalog::with_ledger_store(ledger),
            PrimitiveStores::in_memory(),
        )
    }

    /// Open a host whose ledger and primitive stores share one SQLite file.
    pub fn open_sqlite(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let ledger = SqliteEngineLedgerStore::open(path)?;
        Self::from_catalog_and_primitives(
            LiveCatalog::with_ledger_store(Box::new(ledger)),
            PrimitiveStores::sqlite(path)?,
        )
    }

    /// Wrap an existing catalog and bootstrap engine meta-capabilities.
    pub fn from_catalog(catalog: LiveCatalog) -> Result<Self> {
        Self::from_catalog_and_primitives(catalog, PrimitiveStores::in_memory())
    }

    fn from_catalog_and_primitives(
        catalog: LiveCatalog,
        primitives: PrimitiveStores,
    ) -> Result<Self> {
        let mut host = Self {
            catalog,
            primitives,
        };
        host.bootstrap_meta_capabilities()?;
        Ok(host)
    }

    /// Borrow the live catalog.
    #[must_use]
    pub fn catalog(&self) -> &LiveCatalog {
        &self.catalog
    }

    /// Mutably borrow the live catalog for test/migration setup.
    pub fn catalog_mut(&mut self) -> &mut LiveCatalog {
        &mut self.catalog
    }

    /// Pull catalog changes visible to an actor after a cursor.
    pub fn watch_catalog(
        &self,
        actor: &ActorContext,
        request: EngineWatchRequest,
    ) -> Result<EngineWatchResponse> {
        let current_revision = self.catalog.revision();
        if request.after_revision > current_revision {
            return Ok(EngineWatchResponse {
                changes: Vec::new(),
                current_revision,
                next_revision: current_revision,
                has_more: false,
            });
        }
        if request.limit == 0 {
            return Err(EngineError::PolicyViolation(
                "watch limit must be greater than zero".to_owned(),
            ));
        }

        let limit = request.limit.min(WATCH_MAX_LIMIT);
        let matching = self
            .catalog
            .ledger_catalog_changes()?
            .into_iter()
            .filter(|change| change.after > request.after_revision)
            .filter(|change| is_change_visible_to_actor(change, actor))
            .filter(|change| {
                request
                    .classes
                    .as_ref()
                    .map(|classes| classes.contains(&change.class))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .kinds
                    .as_ref()
                    .map(|kinds| kinds.contains(&change.kind))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .subject_prefix
                    .as_ref()
                    .map(|prefix| change.subject_id.starts_with(prefix))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .owner_worker
                    .as_ref()
                    .map(|owner| change.owner_worker.as_ref() == Some(owner))
                    .unwrap_or(true)
            })
            .collect::<Vec<_>>();
        let has_more = matching.len() > limit;
        let changes = matching.into_iter().take(limit).collect::<Vec<_>>();
        let next_revision = changes
            .last()
            .map(|change| change.after)
            .unwrap_or(request.after_revision);
        Ok(EngineWatchResponse {
            changes,
            current_revision,
            next_revision,
            has_more,
        })
    }

    /// Idempotently register the privileged engine worker and meta-functions.
    pub fn bootstrap_meta_capabilities(&mut self) -> Result<()> {
        let engine_worker_id = worker_id(ENGINE_WORKER_ID)?;
        match self.catalog.worker(&engine_worker_id) {
            Some(worker) => {
                if worker.kind != WorkerKind::System
                    || !worker
                        .namespace_claims
                        .iter()
                        .any(|claim| claim == ENGINE_WORKER_ID)
                {
                    return Err(EngineError::PolicyViolation(
                        "reserved engine namespace already has a non-system owner".to_owned(),
                    ));
                }
            }
            None => {
                self.catalog.register_worker(engine_worker(), false)?;
            }
        }

        for definition in meta_function_definitions()? {
            match self.catalog.function(&definition.id) {
                Some(existing) if existing.owner_worker == engine_worker_id => {
                    if !same_meta_function_contract(existing, &definition) {
                        self.catalog.register_function(definition, None, false)?;
                    }
                }
                Some(existing) => {
                    return Err(EngineError::OwnerMismatch {
                        kind: "function",
                        id: existing.id.to_string(),
                        owner: existing.owner_worker.to_string(),
                        attempted_owner: engine_worker_id.to_string(),
                    });
                }
                None => {
                    self.catalog.register_function(definition, None, false)?;
                }
            }
        }
        self.bootstrap_primitive_capabilities()?;
        Ok(())
    }

    fn bootstrap_primitive_capabilities(&mut self) -> Result<()> {
        for worker in primitive_workers()? {
            let worker_id = worker.id.clone();
            match self.catalog.worker(&worker_id) {
                Some(existing)
                    if existing.kind == worker.kind
                        && existing.namespace_claims == worker.namespace_claims => {}
                Some(existing) => {
                    return Err(EngineError::PolicyViolation(format!(
                        "primitive namespace {} already claimed by incompatible worker {:?}",
                        worker_id, existing.kind
                    )));
                }
                None => {
                    self.catalog.register_worker(worker, false)?;
                }
            }
        }

        for (definition, handler) in primitive_function_definitions(&self.primitives)? {
            match self.catalog.function(&definition.id) {
                Some(existing) if existing.owner_worker == definition.owner_worker => {
                    if existing.description != definition.description
                        || existing.visibility != definition.visibility
                        || existing.effect_class != definition.effect_class
                        || existing.required_authority != definition.required_authority
                        || existing.idempotency != definition.idempotency
                    {
                        self.catalog
                            .register_function(definition, Some(handler), false)?;
                    }
                }
                Some(existing) => {
                    return Err(EngineError::OwnerMismatch {
                        kind: "function",
                        id: existing.id.to_string(),
                        owner: existing.owner_worker.to_string(),
                        attempted_owner: definition.owner_worker.to_string(),
                    });
                }
                None => {
                    self.catalog
                        .register_function(definition, Some(handler), false)?;
                }
            }
        }
        Ok(())
    }

    /// Invoke a function through the host.
    pub async fn invoke(&mut self, invocation: Invocation) -> InvocationResult {
        if invocation.function_id.namespace() != ENGINE_WORKER_ID {
            return self.catalog.invoke_sync(invocation).await;
        }

        match invocation.function_id.as_str() {
            DISCOVER_FUNCTION | INSPECT_FUNCTION | WATCH_FUNCTION | PROMOTE_FUNCTION => {
                self.invoke_sync_meta(invocation)
            }
            INVOKE_FUNCTION => self.invoke_delegated(invocation).await,
            _ => self.catalog.invoke_sync(invocation).await,
        }
    }

    fn invoke_sync_meta(&mut self, mut invocation: Invocation) -> InvocationResult {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => return self.meta_error(&invocation, err),
        };

        let idempotency = match self
            .catalog
            .begin_invocation_idempotency(&function, &invocation)
        {
            InvocationIdempotencyDecision::None => None,
            InvocationIdempotencyDecision::Reserved(reservation) => Some(reservation),
            InvocationIdempotencyDecision::Finished { result, scope } => {
                return self
                    .catalog
                    .record_invocation_result(&invocation, result, scope);
            }
        };

        let value = match invocation.function_id.as_str() {
            DISCOVER_FUNCTION => self.meta_discover(&invocation),
            INSPECT_FUNCTION => self.meta_inspect(&invocation),
            WATCH_FUNCTION => self.meta_watch(&invocation),
            PROMOTE_FUNCTION => self.meta_promote(&invocation),
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        };
        self.finish_meta_invocation(invocation, function, value, idempotency)
    }

    async fn invoke_delegated(&mut self, mut invocation: Invocation) -> InvocationResult {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => return self.meta_error(&invocation, err),
        };

        let value = match self.meta_invoke_child(&invocation).await {
            Ok(value) => Ok(value),
            Err(err) => Err(err),
        };
        self.finish_meta_invocation(invocation, function, value, None)
    }

    fn prepare_delegated_invocation(
        &mut self,
        mut invocation: Invocation,
    ) -> PreparedDelegatedInvocationDecision {
        let function = match self.prepare_meta_invocation(&mut invocation) {
            Ok(function) => function,
            Err(err) => {
                return PreparedDelegatedInvocationDecision::Finished(Box::new(
                    self.meta_error(&invocation, err),
                ));
            }
        };

        let child = match delegated_child_invocation(&invocation) {
            Ok(child) => child,
            Err(err) => {
                return PreparedDelegatedInvocationDecision::Finished(Box::new(
                    self.finish_meta_invocation(invocation, function, Err(err), None),
                ));
            }
        };
        let child = self.catalog.prepare_sync_invocation(child);
        PreparedDelegatedInvocationDecision::Execute(Box::new(PreparedDelegatedInvocation {
            meta_invocation: invocation,
            meta_function: function,
            child,
        }))
    }

    fn prepare_meta_invocation(&self, invocation: &mut Invocation) -> Result<FunctionDefinition> {
        let function = self
            .catalog
            .function(&invocation.function_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            })?;

        invocation.causal_context.catalog_revision = self.catalog.revision();
        if let Some(expected) = invocation.expected_function_revision {
            if expected != function.revision {
                return Err(EngineError::StaleFunctionRevision {
                    function_id: invocation.function_id.to_string(),
                    expected: expected.0,
                    actual: function.revision.0,
                });
            }
        }
        policy::validate_invocation(&function, invocation)?;
        if let Some(schema) = &function.request_schema {
            schema::validate_payload(&function.id, "request", schema, &invocation.payload)?;
        }
        Ok(function)
    }

    fn finish_meta_invocation(
        &mut self,
        invocation: Invocation,
        function: FunctionDefinition,
        value: Result<Value>,
        idempotency: Option<IdempotencyReservation>,
    ) -> InvocationResult {
        let mut result = match value {
            Ok(value) => InvocationResult::success(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.catalog.revision(),
                value,
            ),
            Err(err) => InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.catalog.revision(),
                err,
            ),
        };
        let idempotency_scope = idempotency
            .as_ref()
            .map(|reservation| reservation.key.scope.clone());
        if let Some(reservation) = &idempotency {
            if let Some(completion_error) = self.catalog.complete_invocation_idempotency(
                reservation,
                &invocation,
                &function,
                &result,
            ) {
                result = completion_error;
            }
        }
        self.catalog
            .record_invocation_result(&invocation, result, idempotency_scope)
    }

    fn meta_error(&mut self, invocation: &Invocation, err: EngineError) -> InvocationResult {
        let worker_id = self
            .catalog
            .function(&invocation.function_id)
            .map(|function| function.owner_worker.clone())
            .unwrap_or_else(|| worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"));
        let revision = self
            .catalog
            .function(&invocation.function_id)
            .map(|function| function.revision)
            .unwrap_or(FunctionRevision(0));
        let result = InvocationResult::error(
            invocation,
            worker_id,
            revision,
            self.catalog.revision(),
            err,
        );
        self.catalog
            .record_invocation_result(invocation, result, None)
    }

    fn meta_discover(&self, invocation: &Invocation) -> Result<Value> {
        let payload = &invocation.payload;
        let query = FunctionQuery {
            actor: Some(actor_context(&invocation.causal_context)),
            visibility: optional_visibility(payload.get("visibility"))?,
            namespace_prefix: optional_string(payload.get("namespacePrefix"))?,
            text: optional_string(payload.get("text"))?,
            effect_class: optional_effect(payload.get("effectClass"))?,
            max_risk: optional_risk(payload.get("maxRisk"))?,
            health: optional_health(payload.get("health"))?,
            include_internal: payload
                .get("includeInternal")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        };
        let functions = self.catalog.discover_functions(&query);
        Ok(json!({
            "catalogRevision": self.catalog.revision().0,
            "functions": functions,
        }))
    }

    fn meta_inspect(&self, invocation: &Invocation) -> Result<Value> {
        let kind = required_str(&invocation.payload, "kind")?;
        let id = required_str(&invocation.payload, "id")?;
        let actor = actor_context(&invocation.causal_context);
        let definition = match kind {
            "function" => {
                let definition = self
                    .catalog
                    .inspect_function(&function_id(id)?, Some(&actor))?;
                json!(definition)
            }
            "worker" => {
                let definition = self.catalog.inspect_worker(&worker_id(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "worker {id} is not visible"
                    )));
                }
                json!(definition)
            }
            "trigger_type" => {
                let definition = self
                    .catalog
                    .inspect_trigger_type(&super::ids::TriggerTypeId::new(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "trigger type {id} is not visible"
                    )));
                }
                json!(definition)
            }
            "trigger" => {
                let definition = self
                    .catalog
                    .inspect_trigger(&super::ids::TriggerId::new(id)?)?;
                if !is_visibility_visible(
                    &definition.visibility,
                    definition.provenance.session_id.as_deref(),
                    definition.provenance.workspace_id.as_deref(),
                    &actor,
                ) {
                    return Err(EngineError::PolicyViolation(format!(
                        "trigger {id} is not visible"
                    )));
                }
                json!(definition)
            }
            _ => {
                return Err(EngineError::PolicyViolation(format!(
                    "unsupported inspect kind {kind}"
                )));
            }
        };
        Ok(json!({
            "catalogRevision": self.catalog.revision().0,
            "kind": kind,
            "definition": definition,
        }))
    }

    fn meta_watch(&self, invocation: &Invocation) -> Result<Value> {
        let actor = actor_context(&invocation.causal_context);
        let response =
            self.watch_catalog(&actor, watch_request_from_payload(&invocation.payload)?)?;
        let changes = response
            .changes
            .iter()
            .map(catalog_change_value)
            .collect::<Vec<_>>();
        Ok(json!({
            "changes": changes,
            "currentRevision": response.current_revision.0,
            "nextRevision": response.next_revision.0,
            "hasMore": response.has_more,
        }))
    }

    async fn meta_invoke_child(&mut self, invocation: &Invocation) -> Result<Value> {
        let child = delegated_child_invocation(invocation)?;
        let child_result = self.catalog.invoke_sync(child).await;
        Ok(delegated_invoke_value(
            self.catalog.revision(),
            &child_result,
        ))
    }

    fn meta_promote(&mut self, invocation: &Invocation) -> Result<Value> {
        let function_id = function_id(required_str(&invocation.payload, "functionId")?)?;
        let owner_worker = worker_id(required_str(&invocation.payload, "ownerWorker")?)?;
        let target = required_visibility(&invocation.payload, "targetVisibility")?;
        let expected_revision = FunctionRevision(required_u64(
            &invocation.payload,
            "expectedFunctionRevision",
        )?);
        let workspace_id = optional_string(invocation.payload.get("workspaceId"))?;

        let function = self
            .catalog
            .function(&function_id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "function",
                id: function_id.to_string(),
            })?;
        if function.revision != expected_revision {
            return Err(EngineError::StaleFunctionRevision {
                function_id: function_id.to_string(),
                expected: expected_revision.0,
                actual: function.revision.0,
            });
        }
        if function.visibility != VisibilityScope::Session {
            return Err(EngineError::InvalidVisibilityPromotion {
                function_id: function_id.to_string(),
                target: target.as_str().to_owned(),
                reason: "only session-visible functions can be promoted by engine::promote"
                    .to_owned(),
            });
        }
        let actor = actor_context(&invocation.causal_context);
        if !actor.actor_kind.is_admin_like()
            && function.provenance.session_id.as_deref() != actor.session_id.as_deref()
        {
            return Err(EngineError::PolicyViolation(
                "cannot promote function from a different session".to_owned(),
            ));
        }
        match target {
            VisibilityScope::Workspace => {
                if !invocation
                    .causal_context
                    .has_scope("engine.promote.workspace")
                {
                    return Err(EngineError::PolicyViolation(format!(
                        "missing required authority scope {} for {}",
                        "engine.promote.workspace", PROMOTE_FUNCTION
                    )));
                }
            }
            VisibilityScope::System => {
                if !invocation.causal_context.has_scope("engine.promote.system") {
                    return Err(EngineError::PolicyViolation(format!(
                        "missing required authority scope {} for {}",
                        "engine.promote.system", PROMOTE_FUNCTION
                    )));
                }
            }
            _ => {
                return Err(EngineError::InvalidVisibilityPromotion {
                    function_id: function_id.to_string(),
                    target: target.as_str().to_owned(),
                    reason: "engine::promote only supports workspace or system targets".to_owned(),
                });
            }
        }

        let revision = self.catalog.promote_function_visibility(
            &function_id,
            &owner_worker,
            target.clone(),
            workspace_id,
        )?;
        Ok(json!({
            "functionId": function_id.as_str(),
            "revision": revision.0,
            "visibility": target.as_str(),
            "catalogRevision": self.catalog.revision().0,
        }))
    }
}

fn engine_worker() -> WorkerDefinition {
    WorkerDefinition::new(
        worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"),
        WorkerKind::System,
        actor_id(ENGINE_OWNER_ACTOR).expect("valid engine owner actor"),
        grant_id(ENGINE_AUTHORITY_GRANT).expect("valid engine authority grant"),
    )
    .with_namespace_claim(ENGINE_WORKER_ID)
}

fn meta_function_definitions() -> Result<Vec<FunctionDefinition>> {
    let owner = worker_id(ENGINE_WORKER_ID)?;
    let mut definitions = vec![
        meta_function(
            DISCOVER_FUNCTION,
            "discover live engine capabilities",
            EffectClass::PureRead,
        )
        .with_request_schema(discover_schema()),
        meta_function(
            INSPECT_FUNCTION,
            "inspect a live engine catalog item",
            EffectClass::PureRead,
        )
        .with_request_schema(inspect_schema()),
        meta_function(
            WATCH_FUNCTION,
            "watch catalog changes by cursor",
            EffectClass::PureRead,
        )
        .with_request_schema(watch_schema()),
        meta_function(
            INVOKE_FUNCTION,
            "invoke another engine capability",
            EffectClass::DelegatedInvocation,
        )
        .with_request_schema(invoke_schema()),
        meta_function(
            PROMOTE_FUNCTION,
            "promote a session capability to a wider scope",
            EffectClass::IdempotentWrite,
        )
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_risk(RiskLevel::Medium)
        .with_request_schema(promote_schema()),
    ];
    for definition in &mut definitions {
        definition.owner_worker = owner.clone();
        definition.opaque_response = true;
        definition.provenance = Provenance::system();
    }
    Ok(definitions)
}

fn same_meta_function_contract(
    existing: &FunctionDefinition,
    expected: &FunctionDefinition,
) -> bool {
    existing.id == expected.id
        && existing.owner_worker == expected.owner_worker
        && existing.description == expected.description
        && existing.request_schema == expected.request_schema
        && existing.response_schema == expected.response_schema
        && existing.opaque_response == expected.opaque_response
        && existing.tags == expected.tags
        && existing.visibility == expected.visibility
        && existing.effect_class == expected.effect_class
        && existing.risk_level == expected.risk_level
        && existing.idempotency == expected.idempotency
        && existing.required_authority == expected.required_authority
        && existing.allowed_delivery_modes == expected.allowed_delivery_modes
        && existing.health == expected.health
        && existing.provenance == expected.provenance
        && existing.metadata == expected.metadata
}

fn meta_function(id: &str, description: &str, effect: EffectClass) -> FunctionDefinition {
    FunctionDefinition::new(
        function_id(id).expect("valid static engine function id"),
        worker_id(ENGINE_WORKER_ID).expect("valid engine worker id"),
        description,
        VisibilityScope::Agent,
        effect,
    )
}

fn discover_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "visibility": {"type": "string"},
            "namespacePrefix": {"type": "string"},
            "text": {"type": "string"},
            "effectClass": {"type": "string"},
            "maxRisk": {"type": "string"},
            "health": {"type": "string"},
            "includeInternal": {"type": "boolean"}
        }
    })
}

fn inspect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "id"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
            "id": {"type": "string"}
        }
    })
}

fn watch_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "afterRevision": {"type": "integer"},
            "limit": {"type": "integer"},
            "classes": {"type": "array", "items": {"type": "string"}},
            "kinds": {"type": "array", "items": {"type": "string"}},
            "subjectPrefix": {"type": "string"},
            "ownerWorker": {"type": "string"}
        }
    })
}

fn invoke_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {},
            "expectedFunctionRevision": {"type": "integer"},
            "deliveryMode": {"type": "string", "enum": ["sync"]},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn promote_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId", "ownerWorker", "targetVisibility", "expectedFunctionRevision"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "ownerWorker": {"type": "string"},
            "targetVisibility": {"type": "string", "enum": ["workspace", "system"]},
            "expectedFunctionRevision": {"type": "integer"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn primitive_workers() -> Result<Vec<WorkerDefinition>> {
    Ok(vec![
        WorkerDefinition::new(
            worker_id(STREAM_WORKER_ID)?,
            WorkerKind::Stream,
            actor_id(ENGINE_OWNER_ACTOR)?,
            grant_id(ENGINE_AUTHORITY_GRANT)?,
        )
        .with_namespace_claim(STREAM_WORKER_ID),
        WorkerDefinition::new(
            worker_id(STATE_WORKER_ID)?,
            WorkerKind::State,
            actor_id(ENGINE_OWNER_ACTOR)?,
            grant_id(ENGINE_AUTHORITY_GRANT)?,
        )
        .with_namespace_claim(STATE_WORKER_ID),
        WorkerDefinition::new(
            worker_id(QUEUE_WORKER_ID)?,
            WorkerKind::Queue,
            actor_id(ENGINE_OWNER_ACTOR)?,
            grant_id(ENGINE_AUTHORITY_GRANT)?,
        )
        .with_namespace_claim(QUEUE_WORKER_ID),
        WorkerDefinition::new(
            worker_id(APPROVAL_WORKER_ID)?,
            WorkerKind::System,
            actor_id(ENGINE_OWNER_ACTOR)?,
            grant_id(ENGINE_AUTHORITY_GRANT)?,
        )
        .with_namespace_claim(APPROVAL_WORKER_ID),
    ])
}

fn primitive_function_definitions(
    stores: &PrimitiveStores,
) -> Result<Vec<(FunctionDefinition, Arc<dyn InProcessFunctionHandler>)>> {
    let stream_handler = Arc::new(StreamPrimitiveHandler {
        store: stores.streams.clone(),
    });
    let state_handler = Arc::new(StatePrimitiveHandler {
        store: stores.state.clone(),
    });
    let queue_handler = Arc::new(QueuePrimitiveHandler {
        store: stores.queue.clone(),
    });
    let approval_handler = Arc::new(ApprovalPrimitiveHandler {
        store: stores.approvals.clone(),
    });

    Ok(vec![
        (
            primitive_function(
                "stream::subscribe",
                STREAM_WORKER_ID,
                "subscribe to a cursor-pull stream",
                EffectClass::IdempotentWrite,
                "stream.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(stream_subscribe_schema())
            .with_response_schema(stream_subscribe_response_schema()),
            stream_handler.clone(),
        ),
        (
            primitive_function(
                "stream::poll",
                STREAM_WORKER_ID,
                "poll a stream subscription",
                EffectClass::PureRead,
                "stream.read",
            )
            .with_request_schema(stream_poll_schema())
            .with_response_schema(stream_poll_response_schema()),
            stream_handler.clone(),
        ),
        (
            primitive_function(
                "stream::unsubscribe",
                STREAM_WORKER_ID,
                "unsubscribe from a stream",
                EffectClass::IdempotentWrite,
                "stream.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(stream_unsubscribe_schema())
            .with_response_schema(boolean_response_schema("unsubscribed")),
            stream_handler.clone(),
        ),
        (
            FunctionDefinition::new(
                function_id("stream::publish")?,
                worker_id(STREAM_WORKER_ID)?,
                "publish an internal stream event",
                VisibilityScope::Internal,
                EffectClass::AppendOnlyEvent,
            )
            .with_required_authority(AuthorityRequirement::scope("stream.write"))
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(stream_publish_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["cursor"],
                "additionalProperties": false,
                "properties": {"cursor": {"type": "integer"}}
            })),
            stream_handler,
        ),
        (
            primitive_function(
                "state::get",
                STATE_WORKER_ID,
                "read scoped engine state",
                EffectClass::PureRead,
                "state.read",
            )
            .with_request_schema(state_key_schema())
            .with_response_schema(state_entry_response_schema(true)),
            state_handler.clone(),
        ),
        (
            primitive_function(
                "state::set",
                STATE_WORKER_ID,
                "write scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_set_schema())
            .with_response_schema(state_entry_response_schema(false)),
            state_handler.clone(),
        ),
        (
            primitive_function(
                "state::delete",
                STATE_WORKER_ID,
                "delete scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_key_schema())
            .with_response_schema(boolean_response_schema("deleted")),
            state_handler.clone(),
        ),
        (
            primitive_function(
                "state::compare_and_set",
                STATE_WORKER_ID,
                "conditionally update scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_compare_and_set_schema())
            .with_response_schema(state_entry_response_schema(false)),
            state_handler.clone(),
        ),
        (
            primitive_function(
                "state::list",
                STATE_WORKER_ID,
                "list scoped engine state",
                EffectClass::PureRead,
                "state.read",
            )
            .with_request_schema(state_list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["entries"],
                "additionalProperties": false,
                "properties": {"entries": {"type": "array"}}
            })),
            state_handler,
        ),
        (
            primitive_function(
                "queue::enqueue",
                QUEUE_WORKER_ID,
                "enqueue a durable engine invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(queue_enqueue_schema())
            .with_response_schema(queue_item_response_schema()),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::claim",
                QUEUE_WORKER_ID,
                "claim a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_claim_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["item"],
                "additionalProperties": false,
                "properties": {"item": {}}
            })),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::complete",
                QUEUE_WORKER_ID,
                "complete a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(boolean_response_schema("completed")),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::fail",
                QUEUE_WORKER_ID,
                "fail or retry a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_fail_schema())
            .with_response_schema(boolean_response_schema("failed")),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::cancel",
                QUEUE_WORKER_ID,
                "cancel a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(boolean_response_schema("cancelled")),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::get",
                QUEUE_WORKER_ID,
                "inspect a queued invocation",
                EffectClass::PureRead,
                "queue.read",
            )
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["item"],
                "additionalProperties": false,
                "properties": {"item": {}}
            })),
            queue_handler.clone(),
        ),
        (
            primitive_function(
                "queue::list",
                QUEUE_WORKER_ID,
                "list queued invocations",
                EffectClass::PureRead,
                "queue.read",
            )
            .with_request_schema(queue_list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["items"],
                "additionalProperties": false,
                "properties": {"items": {"type": "array"}}
            })),
            queue_handler,
        ),
        (
            primitive_function(
                APPROVAL_REQUEST_FUNCTION,
                APPROVAL_WORKER_ID,
                "request approval for a high-risk invocation",
                EffectClass::IdempotentWrite,
                "approval.request",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_risk(RiskLevel::Medium)
            .with_request_schema(approval_request_schema())
            .with_response_schema(approval_record_response_schema()),
            approval_handler.clone(),
        ),
        (
            {
                let mut definition = primitive_function(
                    APPROVAL_RESOLVE_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "resolve and optionally resume an approval",
                    EffectClass::IdempotentWrite,
                    "approval.resolve",
                )
                .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
                .with_risk(RiskLevel::High)
                .with_request_schema(approval_resolve_schema())
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["approval", "child"],
                    "additionalProperties": false,
                    "properties": {
                        "approval": {"type": "object"},
                        "child": {}
                    }
                }));
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler.clone(),
        ),
        (
            {
                let mut definition = primitive_function(
                    APPROVAL_GET_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "get one approval record",
                    EffectClass::PureRead,
                    "approval.read",
                )
                .with_request_schema(approval_get_schema())
                .with_response_schema(approval_nullable_response_schema());
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler.clone(),
        ),
        (
            {
                let mut definition = primitive_function(
                    APPROVAL_LIST_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "list approval records",
                    EffectClass::PureRead,
                    "approval.read",
                )
                .with_request_schema(approval_list_schema())
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["approvals"],
                    "additionalProperties": false,
                    "properties": {"approvals": {"type": "array"}}
                }));
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler,
        ),
    ])
}

fn primitive_function(
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

struct StreamPrimitiveHandler {
    store: Arc<StdMutex<StreamStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for StreamPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "stream::subscribe" => {
                let topic = required_string_owned(&invocation.payload, "topic")?;
                let subscription_id = optional_string(invocation.payload.get("subscriptionId"))?
                    .unwrap_or_else(|| InvocationId::generate().to_string());
                let cursor = StreamCursor(
                    optional_u64(invocation.payload.get("afterCursor"))?.unwrap_or_default(),
                );
                let visibility = optional_visibility(invocation.payload.get("visibility"))?
                    .unwrap_or(VisibilityScope::Session);
                let session_id = optional_string(invocation.payload.get("sessionId"))?
                    .or(invocation.causal_context.session_id.clone());
                let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                    .or(invocation.causal_context.workspace_id.clone());
                let subscription = store.subscribe(
                    subscription_id,
                    topic,
                    cursor,
                    visibility,
                    session_id,
                    workspace_id,
                )?;
                Ok(json!({
                    "subscriptionId": subscription.subscription_id,
                    "topic": subscription.topic,
                    "cursor": subscription.cursor.0,
                    "active": subscription.active,
                }))
            }
            "stream::poll" => {
                let subscription_id = required_str(&invocation.payload, "subscriptionId")?;
                let after = optional_u64(invocation.payload.get("afterCursor"))?.map(StreamCursor);
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                let actor = StreamActorScope {
                    session_id: invocation.causal_context.session_id.clone(),
                    workspace_id: invocation.causal_context.workspace_id.clone(),
                    admin: invocation.causal_context.actor_kind.is_admin_like(),
                };
                let page = store.poll(subscription_id, after, limit, &actor)?;
                Ok(json!({
                    "events": page.events,
                    "nextCursor": page.next_cursor.0,
                    "hasMore": page.has_more,
                }))
            }
            "stream::unsubscribe" => {
                let subscription_id = required_str(&invocation.payload, "subscriptionId")?;
                let unsubscribed = store.unsubscribe(subscription_id)?;
                Ok(json!({ "unsubscribed": unsubscribed }))
            }
            "stream::publish" => {
                let topic = required_string_owned(&invocation.payload, "topic")?;
                let payload = invocation
                    .payload
                    .get("payload")
                    .cloned()
                    .unwrap_or(Value::Null);
                let visibility = optional_visibility(invocation.payload.get("visibility"))?
                    .unwrap_or(VisibilityScope::Session);
                let session_id = optional_string(invocation.payload.get("sessionId"))?
                    .or(invocation.causal_context.session_id.clone());
                let workspace_id = optional_string(invocation.payload.get("workspaceId"))?
                    .or(invocation.causal_context.workspace_id.clone());
                let cursor = store.publish(PublishStreamEvent {
                    topic,
                    payload,
                    visibility,
                    session_id,
                    workspace_id,
                    producer: invocation.function_id.to_string(),
                    trace_id: Some(invocation.causal_context.trace_id.clone()),
                    parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                })?;
                Ok(json!({ "cursor": cursor.0 }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

struct StatePrimitiveHandler {
    store: Arc<StdMutex<StateStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for StatePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "state::get" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key = required_str(&invocation.payload, "key")?;
                Ok(json!({ "entry": store.get(scope, namespace, key)? }))
            }
            "state::set" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_string_owned(&invocation.payload, "namespace")?;
                let key = required_string_owned(&invocation.payload, "key")?;
                let value = invocation
                    .payload
                    .get("value")
                    .cloned()
                    .unwrap_or(Value::Null);
                Ok(json!({ "entry": store.set(scope, namespace, key, value)? }))
            }
            "state::delete" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key = required_str(&invocation.payload, "key")?;
                Ok(json!({ "deleted": store.delete(scope, namespace, key)? }))
            }
            "state::compare_and_set" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_string_owned(&invocation.payload, "namespace")?;
                let key = required_string_owned(&invocation.payload, "key")?;
                let expected_revision = optional_u64(invocation.payload.get("expectedRevision"))?;
                let value = invocation
                    .payload
                    .get("value")
                    .cloned()
                    .unwrap_or(Value::Null);
                Ok(json!({
                    "entry": store.compare_and_set(scope, namespace, key, expected_revision, value)?
                }))
            }
            "state::list" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key_prefix = optional_string(invocation.payload.get("keyPrefix"))?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({
                    "entries": store.list(scope, namespace, key_prefix.as_deref(), limit)?
                }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

struct QueuePrimitiveHandler {
    store: Arc<StdMutex<QueueStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for QueuePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "queue::enqueue" => {
                let queue = required_string_owned(&invocation.payload, "queue")?;
                let function_id = function_id(required_str(&invocation.payload, "functionId")?)?;
                let payload = invocation
                    .payload
                    .get("payload")
                    .cloned()
                    .unwrap_or(Value::Null);
                let item = store.enqueue(EnqueueInvocation {
                    queue,
                    function_id,
                    target_revision: optional_u64(invocation.payload.get("targetRevision"))?
                        .map(FunctionRevision),
                    payload,
                    actor_id: invocation.causal_context.actor_id.clone(),
                    actor_kind: invocation.causal_context.actor_kind.clone(),
                    authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
                    authority_scopes: invocation.causal_context.authority_scopes.clone(),
                    trace_id: invocation.causal_context.trace_id.clone(),
                    parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                    trigger_id: invocation.causal_context.trigger_id.clone(),
                    session_id: invocation.causal_context.session_id.clone(),
                    workspace_id: invocation.causal_context.workspace_id.clone(),
                    idempotency_key: invocation.causal_context.idempotency_key.clone(),
                })?;
                Ok(json!({ "item": item }))
            }
            "queue::claim" => {
                let queue = required_str(&invocation.payload, "queue")?;
                let lease_owner = required_str(&invocation.payload, "leaseOwner")?;
                let lease_ms =
                    optional_u64(invocation.payload.get("leaseMs"))?.unwrap_or(30_000) as i64;
                Ok(json!({ "item": store.claim(queue, lease_owner, lease_ms)? }))
            }
            "queue::complete" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                Ok(json!({ "completed": store.complete(receipt_id)? }))
            }
            "queue::fail" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                let max_attempts =
                    optional_u64(invocation.payload.get("maxAttempts"))?.unwrap_or(3) as u32;
                let backoff_ms =
                    optional_u64(invocation.payload.get("backoffMs"))?.unwrap_or(0) as i64;
                Ok(json!({ "failed": store.fail(receipt_id, max_attempts, backoff_ms)? }))
            }
            "queue::cancel" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                Ok(json!({ "cancelled": store.cancel(receipt_id)? }))
            }
            "queue::get" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                Ok(json!({ "item": store.get(receipt_id)? }))
            }
            "queue::list" => {
                let queue = required_str(&invocation.payload, "queue")?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({ "items": store.list(queue, limit)? }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

struct ApprovalPrimitiveHandler {
    store: Arc<StdMutex<ApprovalStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for ApprovalPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            APPROVAL_REQUEST_FUNCTION => {
                let record = store.request(approval_request_from_invocation(&invocation)?)?;
                Ok(json!({ "approval": record }))
            }
            APPROVAL_GET_FUNCTION => {
                let approval_id = required_str(&invocation.payload, "approvalId")?;
                Ok(json!({ "approval": store.get(approval_id)? }))
            }
            APPROVAL_LIST_FUNCTION => {
                let status = optional_string(invocation.payload.get("status"))?
                    .map(|value| parse_approval_status(&value))
                    .transpose()?;
                let session_id = optional_string(invocation.payload.get("sessionId"))?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({
                    "approvals": store.list(status, session_id.as_deref(), limit)?
                }))
            }
            APPROVAL_RESOLVE_FUNCTION => Err(EngineError::PolicyViolation(
                "approval::resolve must execute through EngineHostHandle so the target invocation can resume".to_owned(),
            )),
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn approval_request_from_invocation(invocation: &Invocation) -> Result<EngineApprovalRequest> {
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

fn state_scope_from_payload(invocation: &Invocation) -> Result<EngineStateScope> {
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

fn required_string_owned(payload: &Value, field: &str) -> Result<String> {
    Ok(required_str(payload, field)?.to_owned())
}

fn boolean_response_schema(field: &str) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(field.to_owned(), json!({"type": "boolean"}));
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": properties
    })
}

fn stream_subscribe_schema() -> Value {
    json!({
        "type": "object",
        "required": ["topic"],
        "additionalProperties": false,
        "properties": {
            "topic": {"type": "string"},
            "subscriptionId": {"type": "string"},
            "afterCursor": {"type": "integer"},
            "visibility": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn stream_subscribe_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId", "topic", "cursor", "active"],
        "additionalProperties": false,
        "properties": {
            "subscriptionId": {"type": "string"},
            "topic": {"type": "string"},
            "cursor": {"type": "integer"},
            "active": {"type": "boolean"}
        }
    })
}

fn stream_poll_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId"],
        "additionalProperties": false,
        "properties": {
            "subscriptionId": {"type": "string"},
            "afterCursor": {"type": "integer"},
            "limit": {"type": "integer"}
        }
    })
}

fn stream_poll_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["events", "nextCursor", "hasMore"],
        "additionalProperties": false,
        "properties": {
            "events": {"type": "array"},
            "nextCursor": {"type": "integer"},
            "hasMore": {"type": "boolean"}
        }
    })
}

fn stream_unsubscribe_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId"],
        "additionalProperties": false,
        "properties": {"subscriptionId": {"type": "string"}}
    })
}

fn stream_publish_schema() -> Value {
    json!({
        "type": "object",
        "required": ["topic", "payload"],
        "additionalProperties": false,
        "properties": {
            "topic": {"type": "string"},
            "payload": {},
            "visibility": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn state_scope_properties() -> Value {
    json!({
        "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
        "sessionId": {"type": "string"},
        "workspaceId": {"type": "string"},
        "namespace": {"type": "string"},
        "key": {"type": "string"}
    })
}

fn state_key_schema() -> Value {
    let mut properties = state_scope_properties();
    if let Some(object) = properties.as_object_mut() {
        object.insert("additionalProperties".to_owned(), json!(false));
    }
    json!({
        "type": "object",
        "required": ["namespace", "key"],
        "additionalProperties": false,
        "properties": state_scope_properties()
    })
}

fn state_set_schema() -> Value {
    let mut properties = state_scope_properties();
    properties["value"] = json!({});
    json!({
        "type": "object",
        "required": ["namespace", "key", "value"],
        "additionalProperties": false,
        "properties": properties
    })
}

fn state_compare_and_set_schema() -> Value {
    let mut properties = state_scope_properties();
    properties["value"] = json!({});
    properties["expectedRevision"] = json!({"type": "integer"});
    json!({
        "type": "object",
        "required": ["namespace", "key", "value"],
        "additionalProperties": false,
        "properties": properties
    })
}

fn state_list_schema() -> Value {
    json!({
        "type": "object",
        "required": ["namespace"],
        "additionalProperties": false,
        "properties": {
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "namespace": {"type": "string"},
            "keyPrefix": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

fn state_entry_response_schema(nullable: bool) -> Value {
    let entry_schema = if nullable {
        json!({})
    } else {
        json!({"type": "object"})
    };
    json!({
        "type": "object",
        "required": ["entry"],
        "additionalProperties": false,
        "properties": {"entry": entry_schema}
    })
}

fn queue_enqueue_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue", "functionId", "payload"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "functionId": {"type": "string"},
            "targetRevision": {"type": "integer"},
            "payload": {}
        }
    })
}

fn queue_claim_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue", "leaseOwner"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "leaseOwner": {"type": "string"},
            "leaseMs": {"type": "integer"}
        }
    })
}

fn queue_receipt_schema() -> Value {
    json!({
        "type": "object",
        "required": ["receiptId"],
        "additionalProperties": false,
        "properties": {"receiptId": {"type": "string"}}
    })
}

fn queue_fail_schema() -> Value {
    json!({
        "type": "object",
        "required": ["receiptId"],
        "additionalProperties": false,
        "properties": {
            "receiptId": {"type": "string"},
            "maxAttempts": {"type": "integer"},
            "backoffMs": {"type": "integer"}
        }
    })
}

fn queue_list_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

fn queue_item_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["item"],
        "additionalProperties": false,
        "properties": {"item": {"type": "object"}}
    })
}

fn approval_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {}
        }
    })
}

fn approval_resolve_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approvalId", "decision"],
        "additionalProperties": false,
        "properties": {
            "approvalId": {"type": "string"},
            "decision": {"type": "string", "enum": ["approve", "deny"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_get_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approvalId"],
        "additionalProperties": false,
        "properties": {
            "approvalId": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "status": {"type": "string"},
            "sessionId": {"type": "string"},
            "limit": {"type": "integer"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_record_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approval"],
        "additionalProperties": false,
        "properties": {"approval": {"type": "object"}}
    })
}

fn approval_nullable_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approval"],
        "additionalProperties": false,
        "properties": {"approval": {}}
    })
}

fn actor_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        authority_grant_id: context.authority_grant_id.clone(),
        authority_scopes: context.authority_scopes.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
    }
}

fn is_change_visible_to_actor(change: &CatalogChange, actor: &ActorContext) -> bool {
    is_visibility_visible(
        &change.visibility,
        change.session_id.as_deref(),
        change.workspace_id.as_deref(),
        actor,
    )
}

fn is_visibility_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
) -> bool {
    match visibility {
        VisibilityScope::Internal => actor.actor_kind.is_admin_like(),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(actor.actor_kind, ActorKind::Client) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(actor.actor_kind, ActorKind::Worker) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, ActorKind::Agent) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
    }
}

fn catalog_change_value(change: &CatalogChange) -> Value {
    json!({
        "id": change.id.as_str(),
        "beforeRevision": change.before.0,
        "afterRevision": change.after.0,
        "kind": change_kind_str(&change.kind),
        "subjectId": change.subject_id.as_str(),
        "subjectKind": change.subject_kind.as_str(),
        "class": change.class.as_str(),
        "visibility": change.visibility.as_str(),
        "sessionId": change.session_id.as_deref(),
        "workspaceId": change.workspace_id.as_deref(),
        "ownerWorker": change.owner_worker.as_ref().map(WorkerId::as_str),
        "timestamp": change.timestamp.to_rfc3339(),
    })
}

fn invocation_result_value(result: &InvocationResult) -> Value {
    json!({
        "invocationId": result.invocation_id.as_str(),
        "functionId": result.function_id.as_str(),
        "workerId": result.worker_id.as_str(),
        "functionRevision": result.function_revision.0,
        "catalogRevision": result.catalog_revision.0,
        "traceId": result.trace_id.as_str(),
        "value": result.value.as_ref(),
        "error": result.error.as_ref().map(error_value),
        "replayedFrom": result.replayed_from.as_ref().map(InvocationId::as_str),
    })
}

fn delegated_invoke_value(
    catalog_revision: CatalogRevision,
    child_result: &InvocationResult,
) -> Value {
    json!({
        "catalogRevision": catalog_revision.0,
        "child": invocation_result_value(child_result),
    })
}

fn delegated_child_invocation(invocation: &Invocation) -> Result<Invocation> {
    let target_id = function_id(required_str(&invocation.payload, "functionId")?)?;
    let payload = invocation
        .payload
        .get("payload")
        .cloned()
        .unwrap_or(Value::Null);
    let expected_revision =
        optional_u64(invocation.payload.get("expectedFunctionRevision"))?.map(FunctionRevision);
    let delivery_mode = optional_delivery_mode(invocation.payload.get("deliveryMode"))?
        .unwrap_or(DeliveryMode::Sync);
    let idempotency_key = optional_string(invocation.payload.get("idempotencyKey"))?;

    let mut child_context = invocation.causal_context.clone();
    child_context.parent_invocation_id = Some(invocation.id.clone());
    child_context.idempotency_key = idempotency_key;
    child_context.delivery_mode = delivery_mode;
    let mut child =
        Invocation::new_sync(target_id, payload, child_context).with_delivery_mode(delivery_mode);
    child.expected_function_revision = expected_revision;
    Ok(child)
}

fn error_value(error: &EngineError) -> Value {
    let stored = StoredEngineError::from_engine_error(error);
    json!({
        "kind": stored.kind,
        "message": stored.message,
        "details": stored.details,
    })
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    value
        .map(|value| {
            value.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be a string".to_owned())
            })
        })
        .transpose()
}

fn parse_approval_decision(value: &str) -> Result<ApprovalDecision> {
    match value {
        "approve" => Ok(ApprovalDecision::Approve),
        "deny" => Ok(ApprovalDecision::Deny),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported approval decision {other}"
        ))),
    }
}

fn parse_approval_status(value: &str) -> Result<ApprovalStatus> {
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

fn required_u64(payload: &Value, field: &str) -> Result<u64> {
    payload.get(field).and_then(Value::as_u64).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an integer"))
    })
}

fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    value
        .map(|value| {
            value.as_u64().ok_or_else(|| {
                EngineError::PolicyViolation("optional field must be an integer".to_owned())
            })
        })
        .transpose()
}

fn watch_limit(value: Option<&Value>) -> Result<usize> {
    let Some(limit) = optional_u64(value)? else {
        return Ok(WATCH_DEFAULT_LIMIT);
    };
    if limit == 0 {
        return Err(EngineError::PolicyViolation(
            "watch limit must be greater than zero".to_owned(),
        ));
    }
    Ok((limit as usize).min(WATCH_MAX_LIMIT))
}

fn watch_request_from_payload(payload: &Value) -> Result<EngineWatchRequest> {
    Ok(EngineWatchRequest {
        after_revision: CatalogRevision(
            optional_u64(payload.get("afterRevision"))?.unwrap_or_default(),
        ),
        limit: watch_limit(payload.get("limit"))?,
        classes: optional_change_classes(payload.get("classes"))?,
        kinds: optional_change_kinds(payload.get("kinds"))?,
        subject_prefix: optional_string(payload.get("subjectPrefix"))?,
        owner_worker: optional_string(payload.get("ownerWorker"))?
            .map(WorkerId::new)
            .transpose()?,
    })
}

fn optional_change_classes(value: Option<&Value>) -> Result<Option<Vec<CatalogChangeClass>>> {
    value
        .map(|value| {
            let items = value.as_array().ok_or_else(|| {
                EngineError::PolicyViolation("classes must be an array".to_owned())
            })?;
            items
                .iter()
                .map(|item| {
                    item.as_str()
                        .ok_or_else(|| {
                            EngineError::PolicyViolation(
                                "classes entries must be strings".to_owned(),
                            )
                        })
                        .and_then(parse_change_class)
                })
                .collect()
        })
        .transpose()
}

fn optional_change_kinds(value: Option<&Value>) -> Result<Option<Vec<CatalogChangeKind>>> {
    value
        .map(|value| {
            let items = value
                .as_array()
                .ok_or_else(|| EngineError::PolicyViolation("kinds must be an array".to_owned()))?;
            items
                .iter()
                .map(|item| {
                    item.as_str()
                        .ok_or_else(|| {
                            EngineError::PolicyViolation("kinds entries must be strings".to_owned())
                        })
                        .and_then(parse_change_kind)
                })
                .collect()
        })
        .transpose()
}

fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
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

fn required_visibility(payload: &Value, field: &str) -> Result<VisibilityScope> {
    parse_visibility(required_str(payload, field)?)
}

fn optional_effect(value: Option<&Value>) -> Result<Option<EffectClass>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("effectClass must be a string".to_owned())
                })
                .and_then(parse_effect)
        })
        .transpose()
}

fn optional_risk(value: Option<&Value>) -> Result<Option<RiskLevel>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::PolicyViolation("maxRisk must be a string".to_owned()))
                .and_then(parse_risk)
        })
        .transpose()
}

fn optional_health(value: Option<&Value>) -> Result<Option<FunctionHealth>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| EngineError::PolicyViolation("health must be a string".to_owned()))
                .and_then(parse_health)
        })
        .transpose()
}

fn optional_delivery_mode(value: Option<&Value>) -> Result<Option<DeliveryMode>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("deliveryMode must be a string".to_owned())
                })
                .and_then(parse_delivery_mode)
        })
        .transpose()
}

fn parse_visibility(value: &str) -> Result<VisibilityScope> {
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

fn parse_effect(value: &str) -> Result<EffectClass> {
    match value {
        "pure_read" => Ok(EffectClass::PureRead),
        "deterministic_compute" => Ok(EffectClass::DeterministicCompute),
        "delegated_invocation" => Ok(EffectClass::DelegatedInvocation),
        "idempotent_write" => Ok(EffectClass::IdempotentWrite),
        "append_only_event" => Ok(EffectClass::AppendOnlyEvent),
        "reversible_side_effect" => Ok(EffectClass::ReversibleSideEffect),
        "external_side_effect" => Ok(EffectClass::ExternalSideEffect),
        "irreversible_side_effect" => Ok(EffectClass::IrreversibleSideEffect),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported effect class {value}"
        ))),
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported risk level {value}"
        ))),
    }
}

fn parse_health(value: &str) -> Result<FunctionHealth> {
    match value {
        "healthy" => Ok(FunctionHealth::Healthy),
        "degraded" => Ok(FunctionHealth::Degraded),
        "unhealthy" => Ok(FunctionHealth::Unhealthy),
        "unknown" => Ok(FunctionHealth::Unknown),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported health {value}"
        ))),
    }
}

fn parse_delivery_mode(value: &str) -> Result<DeliveryMode> {
    match value {
        "sync" => Ok(DeliveryMode::Sync),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported delivery mode {value}"
        ))),
    }
}

fn parse_change_class(value: &str) -> Result<CatalogChangeClass> {
    match value {
        "availability" => Ok(CatalogChangeClass::Availability),
        "contract" => Ok(CatalogChangeClass::Contract),
        "trigger" => Ok(CatalogChangeClass::Trigger),
        "visibility" => Ok(CatalogChangeClass::Visibility),
        "health" => Ok(CatalogChangeClass::Health),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported catalog change class {value}"
        ))),
    }
}

fn parse_change_kind(value: &str) -> Result<CatalogChangeKind> {
    match value {
        "worker_registered" => Ok(CatalogChangeKind::WorkerRegistered),
        "worker_updated" => Ok(CatalogChangeKind::WorkerUpdated),
        "worker_unregistered" => Ok(CatalogChangeKind::WorkerUnregistered),
        "function_registered" => Ok(CatalogChangeKind::FunctionRegistered),
        "function_updated" => Ok(CatalogChangeKind::FunctionUpdated),
        "function_unregistered" => Ok(CatalogChangeKind::FunctionUnregistered),
        "trigger_type_registered" => Ok(CatalogChangeKind::TriggerTypeRegistered),
        "trigger_type_updated" => Ok(CatalogChangeKind::TriggerTypeUpdated),
        "trigger_type_unregistered" => Ok(CatalogChangeKind::TriggerTypeUnregistered),
        "trigger_registered" => Ok(CatalogChangeKind::TriggerRegistered),
        "trigger_updated" => Ok(CatalogChangeKind::TriggerUpdated),
        "trigger_unregistered" => Ok(CatalogChangeKind::TriggerUnregistered),
        "visibility_changed" => Ok(CatalogChangeKind::VisibilityChanged),
        "health_changed" => Ok(CatalogChangeKind::HealthChanged),
        _ => Err(EngineError::PolicyViolation(format!(
            "unsupported catalog change kind {value}"
        ))),
    }
}

fn change_kind_str(kind: &CatalogChangeKind) -> &'static str {
    match kind {
        CatalogChangeKind::WorkerRegistered => "worker_registered",
        CatalogChangeKind::WorkerUpdated => "worker_updated",
        CatalogChangeKind::WorkerUnregistered => "worker_unregistered",
        CatalogChangeKind::FunctionRegistered => "function_registered",
        CatalogChangeKind::FunctionUpdated => "function_updated",
        CatalogChangeKind::FunctionUnregistered => "function_unregistered",
        CatalogChangeKind::TriggerTypeRegistered => "trigger_type_registered",
        CatalogChangeKind::TriggerTypeUpdated => "trigger_type_updated",
        CatalogChangeKind::TriggerTypeUnregistered => "trigger_type_unregistered",
        CatalogChangeKind::TriggerRegistered => "trigger_registered",
        CatalogChangeKind::TriggerUpdated => "trigger_updated",
        CatalogChangeKind::TriggerUnregistered => "trigger_unregistered",
        CatalogChangeKind::VisibilityChanged => "visibility_changed",
        CatalogChangeKind::HealthChanged => "health_changed",
    }
}

fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value)
}

fn function_id(value: &str) -> Result<FunctionId> {
    FunctionId::new(value)
}

fn actor_id(value: &str) -> Result<ActorId> {
    ActorId::new(value)
}

fn grant_id(value: &str) -> Result<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}

#[allow(dead_code)]
fn trace_id(value: &str) -> Result<TraceId> {
    TraceId::new(value)
}

#[allow(dead_code)]
fn invocation_id(value: &str) -> Result<InvocationId> {
    InvocationId::new(value)
}
