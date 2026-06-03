//! Engine host, privileged transport functions, and ledgered invocation.
//!
//! `EngineHost` is the boundary future server/runtime services should use when
//! they need the live capability fabric. It keeps `engine::*` capabilities
//! visible as normal catalog functions while executing them through privileged
//! host code that cannot be replaced by ordinary workers.
//!
//! Submodules keep host responsibilities split by surface: handle constructors,
//! catalog operations, module maintenance queues, invocation orchestration,
//! substrate-store methods, shared invocation helpers, meta-function helpers,
//! and the primitive runtime host.

use std::any::Any;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{DateTime, Utc};
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
use super::queue::{EngineQueueAttemptRecord, EngineQueueItem, EnqueueInvocation};
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
    ResourceLeaseRequirement, RiskLevel, TriggerDefinition, TriggerRevision, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind, WorkerRevision,
};
use super::{policy, schema};

mod catalog_handle;
mod handle;
mod invocation_handle;
mod invocation_support;
mod meta;
mod module_jobs;
mod runtime_host;
mod substrate_handle;

use invocation_support::*;
use meta::*;
pub use meta::{CatalogWatchRequest, CatalogWatchResponse};

struct PreparedDelegatedInvocation {
    meta_invocation: Invocation,
    meta_function: FunctionDefinition,
    child: PreparedDelegatedChild,
}

enum PreparedDelegatedChild {
    Sync(PreparedSyncInvocationDecision),
    UiSubmit(Box<Invocation>),
}

enum PreparedDelegatedInvocationDecision {
    Execute(Box<PreparedDelegatedInvocation>),
    Finished(Box<InvocationResult>),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum InvocationRecordingPolicy {
    RecordAll,
    SkipRetryableQueueDeliveryFailure,
}

pub(in crate::engine) struct QueueTargetInvocation {
    pub result: InvocationResult,
    pub recorded_invocation: bool,
    pub resource_lease_ids: Vec<String>,
    pub compensation_status: Option<String>,
    pub compensation_id: Option<String>,
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
        let mut catalog = LiveCatalog::with_ledger_store(Box::new(ledger));
        catalog.hydrate_durable_catalog_from_ledger()?;
        let mut host = Self::from_catalog_and_primitives(catalog, PrimitiveStores::sqlite(path)?)?;
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
                    if !same_primitive_function_contract(existing, &definition) {
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

        let compensation_contract = function.compensation.clone();
        let lease_result = self.acquire_resource_lease_for_invocation(&function, &invocation);
        let mut lease_ids = Vec::new();
        let value = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = primitives::runtime::dispatch(self, &invocation);
                release_after_primary(self.release_resource_lease_sync(&lease.lease_id), result)
            }
            Ok(None) => primitives::runtime::dispatch(self, &invocation),
            Err(error) => Err(error),
        };
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            lease_ids,
            compensation_contract,
        )
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

        let compensation_contract = function.compensation.clone();
        let lease_result = self.acquire_resource_lease_for_invocation(&function, &invocation);
        let mut lease_ids = Vec::new();
        let value = match lease_result {
            Ok(Some(lease)) => {
                lease_ids.push(lease.lease_id.clone());
                let result = match invocation.function_id.as_str() {
                    DISCOVER_FUNCTION => self.meta_discover(&invocation),
                    INSPECT_FUNCTION => self.meta_inspect(&invocation),
                    WATCH_FUNCTION => self.meta_watch(&invocation),
                    PROMOTE_FUNCTION => self.meta_promote(&invocation),
                    _ => Err(EngineError::NotFound {
                        kind: "function",
                        id: invocation.function_id.to_string(),
                    }),
                };
                release_after_primary(self.release_resource_lease_sync(&lease.lease_id), result)
            }
            Ok(None) => match invocation.function_id.as_str() {
                DISCOVER_FUNCTION => self.meta_discover(&invocation),
                INSPECT_FUNCTION => self.meta_inspect(&invocation),
                WATCH_FUNCTION => self.meta_watch(&invocation),
                PROMOTE_FUNCTION => self.meta_promote(&invocation),
                _ => Err(EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                }),
            },
            Err(error) => Err(error),
        };
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            lease_ids,
            compensation_contract,
        )
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
        let child = if child.function_id.as_str() == primitives::ui::SUBMIT_ACTION_FUNCTION {
            PreparedDelegatedChild::UiSubmit(Box::new(child))
        } else if child.function_id.as_str() == APPROVAL_RESOLVE_FUNCTION {
            PreparedDelegatedChild::Sync(self.catalog.prepare_sync_invocation(child))
        } else if is_host_dispatched_primitive_function(&child.function_id) {
            PreparedDelegatedChild::Sync(PreparedSyncInvocationDecision::Finished(Box::new(
                self.invoke_sync_host_dispatched_primitive(child),
            )))
        } else {
            PreparedDelegatedChild::Sync(self.catalog.prepare_sync_invocation(child))
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
        self.finish_meta_invocation_with_contracts(
            invocation,
            function,
            value,
            idempotency,
            Vec::new(),
            None,
        )
    }

    fn finish_meta_invocation_with_contracts(
        &mut self,
        invocation: Invocation,
        function: FunctionDefinition,
        value: Result<Value>,
        idempotency: Option<IdempotencyReservation>,
        resource_lease_ids: Vec<String>,
        compensation_contract: Option<CompensationContract>,
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
        let compensation_status = compensation_contract
            .as_ref()
            .map(|_| "recorded".to_owned());
        let compensation = self.record_compensation_for_result_sync(
            &invocation,
            compensation_contract,
            &result,
            resource_lease_ids.clone(),
        );
        let compensation_status = compensation
            .as_ref()
            .map(|record| record.status.as_str().to_owned())
            .or(compensation_status);
        self.catalog.record_invocation_result_with_contracts(
            &invocation,
            result,
            idempotency_scope,
            resource_lease_ids,
            compensation_status,
        )
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

fn same_primitive_function_contract(
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
        && existing.resource_lease == expected.resource_lease
        && existing.compensation == expected.compensation
        && existing.output_contract == expected.output_contract
        && existing.required_authority == expected.required_authority
        && existing.allowed_delivery_modes == expected.allowed_delivery_modes
        && existing.health == expected.health
        && existing.provenance == expected.provenance
        && existing.metadata == expected.metadata
}
