//! Agent-facing engine host and privileged meta-capabilities.
//!
//! `EngineHost` is the boundary future server/runtime adapters should use when
//! they need the live capability fabric. It keeps `engine::*` capabilities
//! visible as normal catalog functions while executing them through privileged
//! host code that cannot be replaced by ordinary workers.

use std::any::Any;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::FutureExt as _;
use serde_json::{Value, json};
use tokio::sync::{Mutex, MutexGuard};

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
use super::registry::{InvocationIdempotencyDecision, LiveCatalog, PreparedSyncInvocationDecision};
use super::types::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision, DeliveryMode,
    EffectClass, FunctionDefinition, FunctionHealth, FunctionRevision, IdempotencyContract,
    Provenance, RiskLevel, TriggerDefinition, TriggerTypeDefinition, VisibilityScope,
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
        let store = SqliteEngineLedgerStore::open(path.as_ref())?;
        Ok(Self::from_host(EngineHost::with_ledger_store(Box::new(
            store,
        ))?))
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
        Self::from_catalog(LiveCatalog::new())
    }

    /// Create a host with a caller-supplied ledger.
    pub fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Result<Self> {
        Self::from_catalog(LiveCatalog::with_ledger_store(ledger))
    }

    /// Wrap an existing catalog and bootstrap engine meta-capabilities.
    pub fn from_catalog(catalog: LiveCatalog) -> Result<Self> {
        let mut host = Self { catalog };
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
