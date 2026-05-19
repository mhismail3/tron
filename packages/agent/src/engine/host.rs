//! Engine host, privileged transport functions, and ledgered invocation.
//!
//! `EngineHost` is the boundary future server/runtime services should use when
//! they need the live capability fabric. It keeps `engine::*` capabilities
//! visible as normal catalog functions while executing them through privileged
//! host code that cannot be replaced by ordinary workers.

use std::any::Any;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Datelike, Timelike, Utc};
use futures::FutureExt as _;
use serde_json::{Value, json};
use tokio::sync::{Mutex, MutexGuard};

use crate::shared::logging::{LogQueryOptions, LogStore};

use super::approval::{
    ApprovalDecision, ApprovalStatus, EngineApprovalRecord, EngineApprovalRequest,
};
use super::compensation::{EngineCompensationRecord, compensation_record};
use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, TriggerTypeId,
    WorkerId,
};
use super::invocation::{CausalContext, InProcessFunctionHandler, Invocation, InvocationResult};
use super::leases::{AcquireResourceLease, EngineResourceLease};
use super::ledger::{
    EngineLedgerStore, IdempotencyReservation, SqliteEngineLedgerStore, StoredEngineError,
};
use super::primitives;
use super::primitives::{
    APPROVAL_REQUEST_FUNCTION, APPROVAL_RESOLVE_FUNCTION, PrimitiveStores,
    approval_request_from_invocation, primitive_function_definitions, primitive_workers,
};
use super::queue::{EngineQueueItem, EnqueueInvocation};
use super::registry::{
    InvocationIdempotencyDecision, LiveCatalog, PreparedSyncInvocation,
    PreparedSyncInvocationDecision,
};
use super::streams::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, PublishStreamEvent,
    StreamActorScope, StreamCursor,
};
use super::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CompensationContract, DeliveryMode, EffectClass, FunctionDefinition, FunctionHealth,
    FunctionRevision, IdempotencyContract, Provenance, ResourceLeaseFailureBehavior,
    ResourceLeaseRequirement, RiskLevel, TriggerDefinition, TriggerTypeDefinition, VisibilityScope,
    WorkerDefinition, WorkerKind, WorkerRevision,
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

struct PreparedDelegatedInvocation {
    meta_invocation: Invocation,
    meta_function: FunctionDefinition,
    child: PreparedSyncInvocationDecision,
}

enum PreparedDelegatedInvocationDecision {
    Execute(Box<PreparedDelegatedInvocation>),
    Finished(Box<InvocationResult>),
}

/// Host for the in-process live capability engine.
pub struct EngineHost {
    catalog: LiveCatalog,
    primitives: PrimitiveStores,
    storage_path: Option<PathBuf>,
}

/// Cloneable owner for the live capability engine host.
#[derive(Clone)]
pub struct EngineHostHandle {
    inner: Arc<Mutex<EngineHost>>,
}

impl EngineHostHandle {
    /// Create an in-memory engine host for tests and isolated runtime services.
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
        let stores = host.primitives.clone();
        let handle = Self::from_inner(Arc::new(Mutex::new(host)));
        stores
            .install_engine_host(Arc::downgrade(&handle.inner))
            .expect("engine host handle is installed exactly once");
        handle
    }

    pub(in crate::engine) fn from_inner(inner: Arc<Mutex<EngineHost>>) -> Self {
        Self { inner }
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

    /// Return the SQLite storage path when this host is backed by the durable
    /// engine ledger. In-memory hosts return `None`.
    pub async fn storage_path(&self) -> Option<PathBuf> {
        self.inner.lock().await.storage_path.clone()
    }

    /// Return the SQLite storage path during startup/test setup without waiting
    /// on an already-running host.
    pub fn storage_path_for_setup(&self) -> Result<Option<PathBuf>> {
        Ok(self
            .inner
            .try_lock()
            .map_err(|_| {
                EngineError::PolicyViolation(
                    "engine host is busy during storage path setup".to_owned(),
                )
            })?
            .storage_path
            .clone())
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

    /// Return whether a worker is a volatile runtime registration.
    pub async fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool> {
        self.inner.lock().await.catalog.worker_is_volatile(id)
    }

    /// Return a snapshot of invocation records.
    pub async fn invocation_records(&self) -> Vec<super::invocation::InvocationRecord> {
        self.inner.lock().await.catalog.invocations().to_vec()
    }

    /// Enqueue due module health checks from active activation resources.
    pub async fn enqueue_due_module_health_checks(&self, now: DateTime<Utc>) -> Result<usize> {
        let host = self.inner.lock().await;
        let function_id = FunctionId::new(primitives::module::CHECK_HEALTH_FUNCTION)?;
        let actor = ActorContext::new(
            ActorId::new(ENGINE_OWNER_ACTOR)?,
            ActorKind::System,
            AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
        );
        let function = host.catalog.inspect_function(&function_id, Some(&actor))?;
        let resources = {
            let resources = host.primitives.resources.lock().map_err(|_| {
                EngineError::HandlerFailed("resource store lock poisoned".to_owned())
            })?;
            resources.list(super::resources::ListResources {
                kind: Some(super::resources::ACTIVATION_RECORD_KIND.to_owned()),
                scope: None,
                lifecycle: Some("active".to_owned()),
                limit: 500,
            })?
        };
        let mut enqueued = 0usize;
        for resource in resources {
            let Some((version_id, payload)) = ({
                let resources = host.primitives.resources.lock().map_err(|_| {
                    EngineError::HandlerFailed("resource store lock poisoned".to_owned())
                })?;
                resources
                    .inspect(&resource.resource_id)?
                    .and_then(|inspection| {
                        let current = inspection.resource.current_version_id.clone()?;
                        let payload = inspection
                            .versions
                            .iter()
                            .find(|version| version.version_id == current)?
                            .payload
                            .clone();
                        Some((current, payload))
                    })
            }) else {
                continue;
            };
            let interval = payload
                .get("healthPolicy")
                .and_then(|policy| policy.get("intervalSeconds"))
                .and_then(Value::as_u64)
                .filter(|value| *value > 0);
            let Some(interval) = interval else {
                continue;
            };
            if let Some(checked_at) = payload.get("checkedAt").and_then(Value::as_str)
                && let Ok(checked_at) = DateTime::parse_from_rfc3339(checked_at)
            {
                let elapsed = now
                    .signed_duration_since(checked_at.with_timezone(&Utc))
                    .num_seconds();
                if elapsed >= 0 && elapsed < interval as i64 {
                    continue;
                }
            }
            let bucket = now.timestamp().div_euclid(interval as i64);
            let idempotency_key = format!(
                "module.health:{}:{}:{}",
                resource.resource_id, version_id, bucket
            );
            let already_queued = {
                let queue = host.primitives.queue.lock().map_err(|_| {
                    EngineError::HandlerFailed("queue store lock poisoned".to_owned())
                })?;
                queue
                    .list("module", 500)?
                    .iter()
                    .any(|item| item.idempotency_key.as_deref() == Some(idempotency_key.as_str()))
            };
            if already_queued {
                continue;
            }
            let (session_id, workspace_id) = match &resource.scope {
                super::resources::EngineResourceScope::System => (None, None),
                super::resources::EngineResourceScope::Workspace(id) => (None, Some(id.clone())),
                super::resources::EngineResourceScope::Session(id) => (Some(id.clone()), None),
            };
            let item = EnqueueInvocation {
                queue: "module".to_owned(),
                function_id: function_id.clone(),
                target_revision: Some(function.revision),
                payload: json!({
                    "activationResourceId": resource.resource_id,
                    "activationVersionId": version_id,
                    "expectedCurrentVersionId": version_id,
                    "mode": "scheduled",
                }),
                actor_id: ActorId::new(ENGINE_OWNER_ACTOR)?,
                actor_kind: ActorKind::System,
                authority_grant_id: AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
                authority_scopes: vec!["module.write".to_owned()],
                trace_id: TraceId::generate(),
                parent_invocation_id: None,
                trigger_id: None,
                session_id,
                workspace_id,
                idempotency_key: Some(idempotency_key),
            };
            host.primitives
                .queue
                .lock()
                .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
                .enqueue(item)?;
            enqueued = enqueued.saturating_add(1);
        }
        Ok(enqueued)
    }

    /// Enqueue due module trust audits from active schedule decision resources.
    pub async fn enqueue_due_module_trust_audits(&self, now: DateTime<Utc>) -> Result<usize> {
        let host = self.inner.lock().await;
        let function_id = FunctionId::new(primitives::module::RUN_SCHEDULED_TRUST_AUDIT_FUNCTION)?;
        let actor = ActorContext::new(
            ActorId::new(ENGINE_OWNER_ACTOR)?,
            ActorKind::System,
            AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
        );
        let function = host.catalog.inspect_function(&function_id, Some(&actor))?;
        let resources = {
            let resources = host.primitives.resources.lock().map_err(|_| {
                EngineError::HandlerFailed("resource store lock poisoned".to_owned())
            })?;
            resources.list(super::resources::ListResources {
                kind: Some("decision".to_owned()),
                scope: None,
                lifecycle: Some("final".to_owned()),
                limit: 500,
            })?
        };
        let mut enqueued = 0usize;
        for resource in resources {
            let Some((version_id, payload)) = ({
                let resources = host.primitives.resources.lock().map_err(|_| {
                    EngineError::HandlerFailed("resource store lock poisoned".to_owned())
                })?;
                resources
                    .inspect(&resource.resource_id)?
                    .and_then(|inspection| {
                        let current = inspection.resource.current_version_id.clone()?;
                        let payload = inspection
                            .versions
                            .iter()
                            .find(|version| version.version_id == current)?
                            .payload
                            .clone();
                        Some((current, payload))
                    })
            }) else {
                continue;
            };
            if payload.get("status").and_then(Value::as_str) != Some("active") {
                continue;
            }
            let Some(metadata) = payload.get("metadata").and_then(Value::as_object) else {
                continue;
            };
            if metadata.get("decisionType").and_then(Value::as_str)
                != Some("module_trust_audit_schedule")
            {
                continue;
            }
            let Some(expires_at) = metadata
                .get("expiresAt")
                .and_then(Value::as_str)
                .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
                .map(|value| value.with_timezone(&Utc))
            else {
                continue;
            };
            if expires_at <= now {
                continue;
            }
            let Some(cadence) = metadata.get("cadence").and_then(Value::as_str) else {
                continue;
            };
            let Some(timezone) = metadata
                .get("timezone")
                .and_then(Value::as_str)
                .and_then(|value| value.parse::<chrono_tz::Tz>().ok())
            else {
                continue;
            };
            let Some((hour, minute)) = metadata
                .get("wallClockTime")
                .and_then(Value::as_str)
                .and_then(|value| {
                    primitives::module::parse_trust_audit_wall_clock_time(value).ok()
                })
            else {
                continue;
            };
            let local_now = now.with_timezone(&timezone);
            if local_now.hour() < hour || local_now.hour() == hour && local_now.minute() < minute {
                continue;
            }
            if cadence == "weekly" {
                let Some(day) =
                    metadata
                        .get("dayOfWeek")
                        .and_then(Value::as_str)
                        .and_then(|value| {
                            primitives::module::trust_audit_day_of_week_number(value).ok()
                        })
                else {
                    continue;
                };
                if local_now.weekday().number_from_monday() != day {
                    continue;
                }
            } else if cadence != "daily" {
                continue;
            }
            let due_bucket = match cadence {
                "daily" => format!(
                    "{}T{:02}:{:02}:{}",
                    local_now.date_naive(),
                    hour,
                    minute,
                    timezone
                ),
                "weekly" => format!(
                    "{}-W{:02}-{}T{:02}:{:02}:{}",
                    local_now.iso_week().year(),
                    local_now.iso_week().week(),
                    local_now.weekday().number_from_monday(),
                    hour,
                    minute,
                    timezone
                ),
                _ => continue,
            };
            let idempotency_key = format!(
                "module.trust_audit:{}:{}:{}",
                resource.resource_id, version_id, due_bucket
            );
            let already_queued = {
                let queue = host.primitives.queue.lock().map_err(|_| {
                    EngineError::HandlerFailed("queue store lock poisoned".to_owned())
                })?;
                queue
                    .list("module", 500)?
                    .iter()
                    .any(|item| item.idempotency_key.as_deref() == Some(idempotency_key.as_str()))
            };
            if already_queued {
                continue;
            }
            let (session_id, workspace_id) = match &resource.scope {
                super::resources::EngineResourceScope::System => (None, None),
                super::resources::EngineResourceScope::Workspace(id) => (None, Some(id.clone())),
                super::resources::EngineResourceScope::Session(id) => (Some(id.clone()), None),
            };
            let item = EnqueueInvocation {
                queue: "module".to_owned(),
                function_id: function_id.clone(),
                target_revision: Some(function.revision),
                payload: json!({
                    "scheduleDecisionResourceId": resource.resource_id,
                    "scheduleDecisionVersionId": version_id,
                    "dueBucket": due_bucket,
                }),
                actor_id: ActorId::new(ENGINE_OWNER_ACTOR)?,
                actor_kind: ActorKind::System,
                authority_grant_id: AuthorityGrantId::new(ENGINE_AUTHORITY_GRANT)?,
                authority_scopes: vec!["module.write".to_owned()],
                trace_id: TraceId::generate(),
                parent_invocation_id: None,
                trigger_id: None,
                session_id,
                workspace_id,
                idempotency_key: Some(idempotency_key),
            };
            host.primitives
                .queue
                .lock()
                .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
                .enqueue(item)?;
            enqueued = enqueued.saturating_add(1);
        }
        Ok(enqueued)
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
        request: CatalogWatchRequest,
    ) -> Result<CatalogWatchResponse> {
        self.inner.lock().await.watch_catalog(actor, request)
    }

    /// Return the current live catalog revision.
    pub async fn catalog_revision(&self) -> CatalogRevision {
        self.inner.lock().await.catalog.revision()
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
        self.execute_prepared_regular(*prepared).await
    }

    async fn execute_prepared_regular(&self, prepared: PreparedSyncInvocation) -> InvocationResult {
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
        result
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
                if child.invocation.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
                    self.execute_prepared_approval_resolve(*child).await
                } else {
                    self.execute_prepared_regular(*child).await
                }
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
        prepared: super::registry::PreparedSyncInvocation,
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
        prepared: super::registry::PreparedSyncInvocation,
        result: Result<Value>,
    ) -> InvocationResult {
        self.inner
            .lock()
            .await
            .catalog
            .finish_prepared_sync_invocation(prepared, result)
    }

    /// Lock the host for deep test inspection or narrow bootstrap setup.
    ///
    /// Production invocation/discovery paths should use the intent-shaped
    /// methods on this handle so they do not hold the host mutex across handler
    /// execution.
    pub async fn lock(&self) -> MutexGuard<'_, EngineHost> {
        self.inner.lock().await
    }
}

fn release_after_primary(
    release: Result<Option<EngineResourceLease>>,
    primary: Result<Value>,
) -> Result<Value> {
    match (primary, release) {
        (Ok(value), Ok(_)) => Ok(value),
        (Err(error), Ok(_)) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(release_error)) => {
            tracing::warn!(
                ?release_error,
                "resource lease release failed after engine function already failed"
            );
            Err(error)
        }
    }
}

fn lease_request_from_requirement(
    requirement: &ResourceLeaseRequirement,
    invocation: &Invocation,
) -> Result<AcquireResourceLease> {
    if requirement.resolver_id != "payload_template" {
        return match requirement.failure_behavior {
            ResourceLeaseFailureBehavior::FailClosed => Err(EngineError::PolicyViolation(format!(
                "unsupported resource lease resolver {} for {}",
                requirement.resolver_id, invocation.function_id
            ))),
        };
    }
    if !requirement.exclusive {
        return Err(EngineError::PolicyViolation(format!(
            "resource lease for {} must be exclusive in this engine version",
            invocation.function_id
        )));
    }
    let resource_id = render_resource_template(&requirement.resource_id_template, invocation)?;
    Ok(AcquireResourceLease {
        resource_kind: requirement.resource_kind.clone(),
        resource_id,
        holder_invocation_id: invocation.id.clone(),
        function_id: invocation.function_id.clone(),
        actor_id: invocation.causal_context.actor_id.clone(),
        authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
        trace_id: invocation.causal_context.trace_id.clone(),
        parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
        idempotency_key: invocation.causal_context.idempotency_key.clone(),
        ttl_ms: requirement.ttl_ms,
    })
}

fn render_resource_template(template: &str, invocation: &Invocation) -> Result<String> {
    let mut rendered = String::new();
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        let (prefix, after_start) = rest.split_at(start);
        rendered.push_str(prefix);
        let after_start = &after_start[1..];
        let Some(end) = after_start.find('}') else {
            return Err(EngineError::PolicyViolation(format!(
                "resource lease template {template} has an unclosed field"
            )));
        };
        let (field, after_field) = after_start.split_at(end);
        rendered.push_str(&resource_template_value(invocation, field)?);
        rest = &after_field[1..];
    }
    rendered.push_str(rest);
    if rendered.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease resolved an empty resource id".to_owned(),
        ));
    }
    Ok(rendered)
}

fn resource_template_value(invocation: &Invocation, field: &str) -> Result<String> {
    let field = field.trim();
    if field.is_empty() {
        return Err(EngineError::PolicyViolation(
            "resource lease template field must not be empty".to_owned(),
        ));
    }
    let value = if field.starts_with('/') {
        invocation
            .payload
            .pointer(field)
            .map(ValueRef::Json)
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "resource lease resolver could not find payload field {field}"
                ))
            })?
    } else {
        let payload_value = field
            .split('.')
            .try_fold(&invocation.payload, |value, segment| value.get(segment))
            .map(ValueRef::Json);
        let context_value = resource_template_context_value(invocation, field);
        select_resource_template_value(field, payload_value, context_value)?
    };
    value.into_scalar_string(field)
}

fn select_resource_template_value<'a>(
    field: &str,
    payload_value: Option<ValueRef<'a>>,
    context_value: Option<ValueRef<'a>>,
) -> Result<ValueRef<'a>> {
    match (payload_value, context_value) {
        (Some(payload), Some(context)) => {
            let payload_scalar = payload.scalar_string(field)?;
            let context_scalar = context.scalar_string(field)?;
            if payload_scalar != context_scalar {
                return Err(EngineError::PolicyViolation(format!(
                    "resource lease payload field {field} does not match invocation context"
                )));
            }
            Ok(context)
        }
        (Some(payload), None) => Ok(payload),
        (None, Some(context)) => Ok(context),
        (None, None) => Err(EngineError::PolicyViolation(format!(
            "resource lease resolver could not find payload or invocation context field {field}"
        ))),
    }
}

fn resource_template_context_value<'a>(
    invocation: &'a Invocation,
    field: &str,
) -> Option<ValueRef<'a>> {
    match field {
        "sessionId" | "session_id" => invocation
            .causal_context
            .session_id
            .as_deref()
            .map(ValueRef::BorrowedStr),
        "workspaceId" | "workspace_id" => invocation
            .causal_context
            .workspace_id
            .as_deref()
            .map(ValueRef::BorrowedStr),
        "actorId" | "actor_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.actor_id.to_string(),
        )),
        "authorityGrantId" | "authority_grant_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.authority_grant_id.to_string(),
        )),
        "traceId" | "trace_id" => Some(ValueRef::OwnedString(
            invocation.causal_context.trace_id.to_string(),
        )),
        "invocationId" | "invocation_id" => Some(ValueRef::OwnedString(invocation.id.to_string())),
        "parentInvocationId" | "parent_invocation_id" => invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| ValueRef::OwnedString(id.to_string())),
        "idempotencyKey" | "idempotency_key" => invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .map(ValueRef::BorrowedStr),
        _ => None,
    }
}

enum ValueRef<'a> {
    Json(&'a Value),
    BorrowedStr(&'a str),
    OwnedString(String),
}

impl ValueRef<'_> {
    fn into_scalar_string(self, field: &str) -> Result<String> {
        self.scalar_string(field)
    }

    fn scalar_string(&self, field: &str) -> Result<String> {
        match self {
            Self::Json(Value::String(value)) if !value.trim().is_empty() => Ok(value.clone()),
            Self::Json(Value::Number(value)) => Ok(value.to_string()),
            Self::Json(Value::Bool(value)) => Ok(value.to_string()),
            Self::BorrowedStr(value) if !value.trim().is_empty() => Ok((*value).to_owned()),
            Self::OwnedString(value) if !value.trim().is_empty() => Ok((*value).clone()),
            Self::Json(Value::String(_)) | Self::BorrowedStr(_) | Self::OwnedString(_) => {
                Err(EngineError::PolicyViolation(format!(
                    "resource lease field {field} must not be empty"
                )))
            }
            Self::Json(_) => Err(EngineError::PolicyViolation(format!(
                "resource lease field {field} must be a scalar"
            ))),
        }
    }
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
pub struct CatalogWatchRequest {
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

impl Default for CatalogWatchRequest {
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
pub struct CatalogWatchResponse {
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
        let storage_runtime = crate::shared::storage::StorageRuntime::new(path.to_path_buf());
        storage_runtime
            .prepare_for_startup()
            .map_err(storage_error)?;
        drop(storage_runtime.open_connection().map_err(storage_error)?);
        let _startup_checkpoint = storage_runtime.checkpoint().map_err(storage_error)?;
        let ledger = SqliteEngineLedgerStore::open(path)?;
        let mut host = Self::from_catalog_and_primitives(
            LiveCatalog::with_ledger_store(Box::new(ledger)),
            PrimitiveStores::sqlite(path)?,
        )?;
        host.storage_path = Some(path.to_path_buf());
        Ok(host)
    }

    /// Wrap an existing catalog and bootstrap engine transport functions.
    pub fn from_catalog(catalog: LiveCatalog) -> Result<Self> {
        Self::from_catalog_and_primitives(catalog, PrimitiveStores::in_memory())
    }

    fn from_catalog_and_primitives(
        mut catalog: LiveCatalog,
        primitives: PrimitiveStores,
    ) -> Result<Self> {
        catalog.set_grant_store(primitives.grants.clone());
        let mut host = Self {
            catalog,
            primitives,
            storage_path: None,
        };
        host.bootstrap_meta_capabilities()?;
        Ok(host)
    }

    /// Borrow the live catalog.
    #[must_use]
    pub fn catalog(&self) -> &LiveCatalog {
        &self.catalog
    }

    /// Mutably borrow the live catalog for tests and bootstrap setup.
    pub fn catalog_mut(&mut self) -> &mut LiveCatalog {
        &mut self.catalog
    }

    /// Pull catalog changes visible to an actor after a cursor.
    pub fn watch_catalog(
        &self,
        actor: &ActorContext,
        request: CatalogWatchRequest,
    ) -> Result<CatalogWatchResponse> {
        let current_revision = self.catalog.revision();
        if request.after_revision > current_revision {
            return Ok(CatalogWatchResponse {
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
        Ok(CatalogWatchResponse {
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

        for registration in primitive_function_definitions(&self.primitives)? {
            let definition = registration.definition;
            let handler = registration.handler;
            match self.catalog.function(&definition.id) {
                Some(existing) if existing.owner_worker == definition.owner_worker => {
                    if existing.description != definition.description
                        || existing.visibility != definition.visibility
                        || existing.effect_class != definition.effect_class
                        || existing.required_authority != definition.required_authority
                        || existing.idempotency != definition.idempotency
                    {
                        self.catalog.register_function(definition, handler, false)?;
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
                    self.catalog.register_function(definition, handler, false)?;
                }
            }
        }
        Ok(())
    }

    /// Invoke a function through the host.
    pub async fn invoke(&mut self, invocation: Invocation) -> InvocationResult {
        if invocation.function_id.namespace() != ENGINE_WORKER_ID {
            if is_host_dispatched_primitive_function(&invocation.function_id) {
                return self.invoke_sync_host_dispatched_primitive(invocation);
            }
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

    fn invoke_sync_host_dispatched_primitive(
        &mut self,
        mut invocation: Invocation,
    ) -> InvocationResult {
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

        let value = primitives::runtime::dispatch(self, &invocation);
        self.finish_meta_invocation(invocation, function, value, idempotency)
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
        let child = if child.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
            self.catalog.prepare_sync_invocation(child)
        } else if is_host_dispatched_primitive_function(&child.function_id) {
            PreparedSyncInvocationDecision::Finished(Box::new(
                self.invoke_sync_host_dispatched_primitive(child),
            ))
        } else {
            self.catalog.prepare_sync_invocation(child)
        };
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
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .authorize_invocation(&function, invocation)?;
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
        let child_result = if is_host_dispatched_primitive_function(&child.function_id) {
            self.invoke_sync_host_dispatched_primitive(child)
        } else {
            self.catalog.invoke_sync(child).await
        };
        Ok(delegated_invoke_value(
            self.catalog.revision(),
            &child_result,
        ))
    }

    fn meta_promote(&mut self, invocation: &Invocation) -> Result<Value> {
        let function_id = function_id(required_str(&invocation.payload, "functionId")?)?;
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
        let owner_worker = match optional_string(invocation.payload.get("ownerWorker"))? {
            Some(owner) => worker_id(&owner)?,
            None => function.owner_worker.clone(),
        };
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
            VisibilityScope::Workspace | VisibilityScope::System => {}
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

    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition> {
        self.catalog
            .workers()
            .into_iter()
            .filter(|worker| {
                is_visibility_visible(
                    &worker.visibility,
                    worker.provenance.session_id.as_deref(),
                    worker.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }

    fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition> {
        self.catalog
            .triggers()
            .into_iter()
            .filter(|trigger| {
                is_visibility_visible(
                    &trigger.visibility,
                    trigger.provenance.session_id.as_deref(),
                    trigger.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }

    fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition> {
        self.catalog
            .trigger_types()
            .into_iter()
            .filter(|trigger_type| {
                is_visibility_visible(
                    &trigger_type.visibility,
                    trigger_type.provenance.session_id.as_deref(),
                    trigger_type.provenance.workspace_id.as_deref(),
                    actor,
                )
            })
            .collect()
    }
}

impl primitives::runtime::PrimitiveRuntimeHost for EngineHost {
    fn catalog_revision(&self) -> CatalogRevision {
        self.catalog.revision()
    }

    fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.catalog.discover_functions(query)
    }

    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition> {
        EngineHost::visible_workers(self, actor)
    }

    fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition> {
        EngineHost::visible_triggers(self, actor)
    }

    fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition> {
        EngineHost::visible_trigger_types(self, actor)
    }

    fn inspect_catalog_item(&self, invocation: &Invocation) -> Result<Value> {
        self.meta_inspect(invocation)
    }

    fn watch_catalog_snapshot_base(&self, invocation: &Invocation) -> Result<Value> {
        self.meta_watch(invocation)
    }

    fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition> {
        self.catalog.inspect_worker(id)
    }

    fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool> {
        self.catalog.worker_is_volatile(id)
    }

    fn unregister_worker(&mut self, id: &WorkerId, owner_actor: &str) -> Result<()> {
        self.catalog.unregister_worker(id, owner_actor)
    }

    fn invocations(&self) -> Vec<super::invocation::InvocationRecord> {
        self.catalog.invocations().to_vec()
    }

    fn ledger_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        self.catalog.ledger_catalog_changes()
    }

    fn approval_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineApprovalRecord>> {
        self.primitives
            .approvals
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .list(None, None, 500)
            .map(|records| {
                records
                    .into_iter()
                    .filter(|record| record.trace_id.as_str() == trace_id)
                    .collect()
            })
    }

    fn stream_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineStreamEvent>> {
        self.primitives
            .streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
    }

    fn resource_leases_for_trace(&self, trace_id: &str) -> Result<Vec<EngineResourceLease>> {
        self.primitives
            .leases
            .lock()
            .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
            .list_by_trace(trace_id, 500)
    }

    fn resource_lease(&self, lease_id: &str) -> Result<Option<EngineResourceLease>> {
        self.primitives
            .leases
            .lock()
            .map_err(|_| EngineError::HandlerFailed("lease store lock poisoned".to_owned()))?
            .get(lease_id)
    }

    fn compensation_records_for_trace(&self, trace_id: &str) -> Result<Vec<Value>> {
        self.primitives
            .compensation
            .lock()
            .map_err(|_| EngineError::HandlerFailed("compensation store lock poisoned".to_owned()))?
            .list()
            .map(|records| {
                records
                    .into_iter()
                    .filter(|record| record.trace_id.as_str() == trace_id)
                    .map(|record| json!(record))
                    .collect()
            })
    }

    fn resource_type_definitions(
        &self,
    ) -> Result<Vec<super::resources::EngineResourceTypeDefinition>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list_types()
    }

    fn list_resources(
        &self,
        filter: super::resources::ListResources,
    ) -> Result<Vec<super::resources::EngineResource>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .list(filter)
    }

    fn inspect_resource(
        &self,
        resource_id: &str,
    ) -> Result<Option<super::resources::EngineResourceInspection>> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .inspect(resource_id)
    }

    fn create_resource(
        &mut self,
        request: super::resources::CreateResource,
    ) -> Result<super::resources::EngineResource> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .create(request)
    }

    fn update_resource(
        &mut self,
        request: super::resources::UpdateResource,
    ) -> Result<super::resources::EngineResourceVersion> {
        self.primitives
            .resources
            .lock()
            .map_err(|_| EngineError::HandlerFailed("resource store lock poisoned".to_owned()))?
            .update(request)
    }

    fn list_grants(
        &self,
        filter: super::grants::ListGrants,
    ) -> Result<Vec<super::grants::EngineGrant>> {
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .list(filter)
    }

    fn inspect_grant(
        &self,
        grant_id: &AuthorityGrantId,
    ) -> Result<Option<super::grants::EngineGrant>> {
        self.primitives
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?
            .inspect(grant_id)
    }

    fn queue_items(&self, queue: &str, limit: usize) -> Result<Vec<EngineQueueItem>> {
        self.primitives
            .queue
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?
            .list(queue, limit)
    }

    fn approval_records(
        &self,
        status: Option<ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>> {
        self.primitives
            .approvals
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?
            .list(status, session_id, limit)
    }

    fn worker_count(&self) -> usize {
        self.catalog.workers().len()
    }

    fn function_count(&self) -> usize {
        self.catalog
            .discover_functions(&FunctionQuery::default())
            .len()
    }

    fn trigger_count(&self) -> usize {
        self.catalog.triggers().len()
    }

    fn trigger_type_count(&self) -> usize {
        self.catalog.trigger_types().len()
    }

    fn catalog_change_count(&self) -> usize {
        self.catalog.changes().len()
    }

    fn storage_stats(&self) -> Result<crate::shared::storage::StorageStatsReport> {
        self.storage_runtime()?.stats().map_err(storage_error)
    }

    fn storage_checkpoint(&self) -> Result<crate::shared::storage::StorageCheckpointReport> {
        self.storage_runtime()?.checkpoint().map_err(storage_error)
    }

    fn storage_export_snapshot(
        &self,
        snapshot_path: &str,
    ) -> Result<crate::shared::storage::StorageExportReport> {
        self.storage_runtime()?
            .export_snapshot(snapshot_path)
            .map_err(storage_error)
    }

    fn storage_retention_run(
        &self,
        dry_run: bool,
        verbose_retention_days: u64,
    ) -> Result<crate::shared::storage::StorageRetentionReport> {
        self.storage_runtime()?
            .retention_run(dry_run, verbose_retention_days)
            .map_err(storage_error)
    }

    fn stored_log_values(
        &self,
        query: &LogQueryOptions,
        include_full_payloads: bool,
    ) -> Result<Vec<Value>> {
        let Some(path) = &self.storage_path else {
            return Ok(Vec::new());
        };
        let runtime = crate::shared::storage::StorageRuntime::new(path.clone());
        let conn = runtime.open_connection().map_err(storage_error)?;
        let store = LogStore::new(&conn);
        let mut values = Vec::new();
        for entry in store.query(query) {
            let mut value = json!(entry);
            if include_full_payloads
                && let Some(data) = value.get("data").cloned()
                && data
                    .get(crate::shared::storage::PAYLOAD_REF_ENVELOPE_KEY)
                    .is_some()
            {
                let stored = serde_json::to_string(&data).map_err(|error| {
                    EngineError::HandlerFailed(format!(
                        "storage log payload expansion failed: {error}"
                    ))
                })?;
                if let Ok(expanded) =
                    crate::shared::storage::resolve_stored_json_value(&conn, &stored)
                {
                    value["data"] = expanded;
                }
            }
            values.push(value);
        }
        Ok(values)
    }
}

impl EngineHost {
    fn storage_runtime(&self) -> Result<crate::shared::storage::StorageRuntime> {
        let Some(path) = &self.storage_path else {
            return Err(EngineError::PolicyViolation(
                "storage primitives require a SQLite-backed engine host".to_owned(),
            ));
        };
        Ok(crate::shared::storage::StorageRuntime::new(path.clone()))
    }
}

fn storage_error(error: anyhow::Error) -> EngineError {
    EngineError::HandlerFailed(format!("storage primitive failed: {error:#}"))
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
        .with_required_authority(AuthorityRequirement::scope("engine.promote"))
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
        VisibilityScope::System,
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
        "required": ["functionId", "targetVisibility", "expectedFunctionRevision"],
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

fn watch_request_from_payload(payload: &Value) -> Result<CatalogWatchRequest> {
    Ok(CatalogWatchRequest {
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

fn is_host_dispatched_primitive_namespace(namespace: &str) -> bool {
    matches!(
        namespace,
        "catalog" | "worker" | "control" | "observability" | "storage" | "ui"
    )
}

fn is_host_dispatched_primitive_function(function_id: &FunctionId) -> bool {
    function_id.as_str() != "worker::spawn"
        && is_host_dispatched_primitive_namespace(function_id.namespace())
}
