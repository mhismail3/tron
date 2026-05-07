//! In-memory live catalog registry.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::Utc;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::discovery::{ActorContext, FunctionQuery};
use super::errors::{EngineError, Result};
use super::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use super::invocation::{InProcessFunctionHandler, Invocation, InvocationRecord, InvocationResult};
use super::ledger::{
    EngineLedgerStore, IdempotencyEntry, IdempotencyKey, IdempotencyReservation,
    IdempotencyReservationOutcome, IdempotencyStatus, InMemoryEngineLedgerStore,
    StoredInvocationOutcome,
};
use super::policy;
use super::schema;
use super::types::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision, CatalogSubjectKind,
    FunctionDefinition, FunctionRevision, IdempotencyScope, LedgerKind, Provenance, ReplayBehavior,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerRevision,
};

const RESERVED_ENGINE_NAMESPACE: &str = "engine";
const RESERVED_ENGINE_WORKER_ID: &str = "engine";

struct WorkerEntry {
    definition: WorkerDefinition,
    volatile: bool,
}

struct FunctionEntry {
    definition: FunctionDefinition,
    handler: Option<Arc<dyn InProcessFunctionHandler>>,
    volatile: bool,
}

struct TriggerTypeEntry {
    definition: TriggerTypeDefinition,
    volatile: bool,
}

struct TriggerEntry {
    definition: TriggerDefinition,
    volatile: bool,
}

#[derive(Clone)]
struct CatalogChangeSubject {
    id: String,
    kind: CatalogSubjectKind,
    visibility: VisibilityScope,
    session_id: Option<String>,
    workspace_id: Option<String>,
    owner_worker: Option<WorkerId>,
}

/// Idempotency decision for an invocation before the handler or built-in runs.
pub(in crate::engine) enum InvocationIdempotencyDecision {
    /// No idempotency reservation is required.
    None,
    /// This invocation owns a fresh reservation and may execute.
    Reserved(IdempotencyReservation),
    /// A replay/conflict/error result has already been determined.
    Finished {
        /// Result to record and return.
        result: InvocationResult,
        /// Concrete idempotency scope, if one was resolved.
        scope: Option<IdempotencyScope>,
    },
}

/// A sync invocation that passed routing, policy, schema, and idempotency
/// reservation checks and is ready to execute outside the catalog lock.
pub(in crate::engine) struct PreparedSyncInvocation {
    /// Invocation with its causal catalog revision captured at prepare time.
    pub invocation: Invocation,
    /// Function contract captured at prepare time.
    pub function: FunctionDefinition,
    /// In-process handler captured at prepare time.
    pub handler: Arc<dyn InProcessFunctionHandler>,
    /// Fresh idempotency reservation, when the function is mutating.
    pub idempotency: Option<IdempotencyReservation>,
}

/// Prepare result for a sync invocation.
pub(in crate::engine) enum PreparedSyncInvocationDecision {
    /// The handler should be executed outside the catalog lock.
    Execute(Box<PreparedSyncInvocation>),
    /// The invocation already finished during prepare, usually due to policy,
    /// schema, routing, or idempotency replay/conflict behavior.
    Finished(Box<InvocationResult>),
}

/// In-memory live catalog.
pub struct LiveCatalog {
    revision: CatalogRevision,
    workers: BTreeMap<WorkerId, WorkerEntry>,
    functions: BTreeMap<FunctionId, FunctionEntry>,
    trigger_types: BTreeMap<TriggerTypeId, TriggerTypeEntry>,
    triggers: BTreeMap<TriggerId, TriggerEntry>,
    changes: Vec<CatalogChange>,
    invocations: Vec<InvocationRecord>,
    ledger: Box<dyn EngineLedgerStore>,
}

impl LiveCatalog {
    /// Create an empty live catalog.
    #[must_use]
    pub fn new() -> Self {
        Self::with_ledger_store(Box::new(InMemoryEngineLedgerStore::new()))
    }

    /// Create an empty live catalog using a caller-supplied ledger store.
    #[must_use]
    pub fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Self {
        Self {
            revision: CatalogRevision(0),
            workers: BTreeMap::new(),
            functions: BTreeMap::new(),
            trigger_types: BTreeMap::new(),
            triggers: BTreeMap::new(),
            changes: Vec::new(),
            invocations: Vec::new(),
            ledger,
        }
    }

    /// Current catalog revision.
    #[must_use]
    pub fn revision(&self) -> CatalogRevision {
        self.revision
    }

    /// Catalog change log.
    #[must_use]
    pub fn changes(&self) -> &[CatalogChange] {
        &self.changes
    }

    /// Invocation ledger.
    #[must_use]
    pub fn invocations(&self) -> &[InvocationRecord] {
        &self.invocations
    }

    /// Durable catalog changes recorded by the engine ledger.
    pub fn catalog_changes_after(
        &self,
        revision: CatalogRevision,
        limit: usize,
    ) -> Result<Vec<CatalogChange>> {
        self.ledger.catalog_changes_after(revision, limit)
    }

    /// All durable catalog changes recorded by the engine ledger.
    pub fn ledger_catalog_changes(&self) -> Result<Vec<CatalogChange>> {
        self.ledger.list_catalog_changes()
    }

    /// Register or update a worker.
    pub fn register_worker(
        &mut self,
        mut definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
        validate_worker_namespace_claims(&definition)?;
        let kind = if let Some(existing) = self.workers.get(&definition.id) {
            if existing.definition.owner_actor != definition.owner_actor {
                return Err(EngineError::OwnerMismatch {
                    kind: "worker",
                    id: definition.id.to_string(),
                    owner: existing.definition.owner_actor.to_string(),
                    attempted_owner: definition.owner_actor.to_string(),
                });
            }
            definition.revision = existing.definition.revision.next();
            CatalogChangeKind::WorkerUpdated
        } else {
            definition.revision = WorkerRevision(1);
            CatalogChangeKind::WorkerRegistered
        };

        let revision = definition.revision;
        let subject = worker_change_subject(&definition);
        self.record_change(kind, subject)?;
        let _ = self.workers.insert(
            definition.id.clone(),
            WorkerEntry {
                definition,
                volatile,
            },
        );
        Ok(revision)
    }

    /// Get a worker definition.
    #[must_use]
    pub fn worker(&self, id: &WorkerId) -> Option<&WorkerDefinition> {
        self.workers.get(id).map(|entry| &entry.definition)
    }

    /// Inspect a worker definition.
    pub fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition> {
        self.worker(id)
            .cloned()
            .ok_or_else(|| EngineError::NotFound {
                kind: "worker",
                id: id.to_string(),
            })
    }

    /// Whether a worker registration is volatile.
    #[must_use]
    pub fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool> {
        self.workers.get(id).map(|entry| entry.volatile)
    }

    /// List workers in deterministic order.
    #[must_use]
    pub fn workers(&self) -> Vec<WorkerDefinition> {
        self.workers
            .values()
            .map(|entry| entry.definition.clone())
            .collect()
    }

    /// Unregister a worker by owner actor.
    pub fn unregister_worker(&mut self, id: &WorkerId, owner_actor: &str) -> Result<()> {
        let Some(entry) = self.workers.get(id) else {
            return Err(EngineError::NotFound {
                kind: "worker",
                id: id.to_string(),
            });
        };
        if entry.definition.owner_actor.as_str() != owner_actor {
            return Err(EngineError::OwnerMismatch {
                kind: "worker",
                id: id.to_string(),
                owner: entry.definition.owner_actor.to_string(),
                attempted_owner: owner_actor.to_owned(),
            });
        }
        let subject = worker_change_subject(&entry.definition);
        self.cleanup_owned_volatile(id)?;
        self.record_change(CatalogChangeKind::WorkerUnregistered, subject)?;
        let _ = self.workers.remove(id);
        Ok(())
    }

    /// Register or update a function.
    pub fn register_function(
        &mut self,
        mut definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
        validate_reserved_function_namespace(&definition)?;
        let owner = self
            .worker(&definition.owner_worker)
            .ok_or_else(|| EngineError::NotFound {
                kind: "worker",
                id: definition.owner_worker.to_string(),
            })?;
        if !owner
            .namespace_claims
            .iter()
            .any(|claim| claim == definition.id.namespace())
        {
            return Err(EngineError::NamespaceDenied {
                worker_id: definition.owner_worker.to_string(),
                function_id: definition.id.to_string(),
            });
        }
        policy::validate_function_registration(&definition)?;

        let kind = if let Some(existing) = self.functions.get(&definition.id) {
            if existing.definition.owner_worker != definition.owner_worker {
                return Err(EngineError::OwnerMismatch {
                    kind: "function",
                    id: definition.id.to_string(),
                    owner: existing.definition.owner_worker.to_string(),
                    attempted_owner: definition.owner_worker.to_string(),
                });
            }
            definition.revision = existing.definition.revision.next();
            CatalogChangeKind::FunctionUpdated
        } else {
            definition.revision = FunctionRevision(1);
            CatalogChangeKind::FunctionRegistered
        };

        let revision = definition.revision;
        let subject = function_change_subject(&definition);
        self.record_change(kind, subject)?;
        let _ = self.functions.insert(
            definition.id.clone(),
            FunctionEntry {
                definition,
                handler,
                volatile,
            },
        );
        Ok(revision)
    }

    /// Get a function.
    #[must_use]
    pub fn function(&self, id: &FunctionId) -> Option<&FunctionDefinition> {
        self.functions.get(id).map(|entry| &entry.definition)
    }

    /// Inspect a function if it is visible to the actor.
    pub fn inspect_function(
        &self,
        id: &FunctionId,
        actor: Option<&ActorContext>,
    ) -> Result<FunctionDefinition> {
        let function = self.function(id).ok_or_else(|| EngineError::NotFound {
            kind: "function",
            id: id.to_string(),
        })?;
        if !policy::is_visible_to_actor(function, actor) {
            return Err(EngineError::PolicyViolation(format!(
                "function {id} is not visible"
            )));
        }
        Ok(function.clone())
    }

    /// Unregister a function.
    pub fn unregister_function(&mut self, id: &FunctionId, owner: &WorkerId) -> Result<()> {
        let Some(entry) = self.functions.get(id) else {
            return Err(EngineError::NotFound {
                kind: "function",
                id: id.to_string(),
            });
        };
        if &entry.definition.owner_worker != owner {
            return Err(EngineError::OwnerMismatch {
                kind: "function",
                id: id.to_string(),
                owner: entry.definition.owner_worker.to_string(),
                attempted_owner: owner.to_string(),
            });
        }
        let subject = function_change_subject(&entry.definition);
        self.cleanup_triggers_targeting(id)?;
        self.record_change(CatalogChangeKind::FunctionUnregistered, subject)?;
        let _ = self.functions.remove(id).expect("entry exists");
        Ok(())
    }

    /// Promote a function from session scope to workspace or system visibility.
    pub fn promote_function_visibility(
        &mut self,
        id: &FunctionId,
        owner: &WorkerId,
        target: VisibilityScope,
        workspace_id: Option<String>,
    ) -> Result<FunctionRevision> {
        let Some(entry) = self.functions.get(id) else {
            return Err(EngineError::NotFound {
                kind: "function",
                id: id.to_string(),
            });
        };
        if &entry.definition.owner_worker != owner {
            return Err(EngineError::OwnerMismatch {
                kind: "function",
                id: id.to_string(),
                owner: entry.definition.owner_worker.to_string(),
                attempted_owner: owner.to_string(),
            });
        }

        let mut updated = entry.definition.clone();
        match target {
            VisibilityScope::Workspace if workspace_id.is_some() => {
                updated.visibility = VisibilityScope::Workspace;
                updated.provenance.session_id = None;
                updated.provenance.workspace_id = workspace_id;
            }
            VisibilityScope::System => {
                updated.visibility = VisibilityScope::System;
                updated.provenance.session_id = None;
                updated.provenance.workspace_id = None;
            }
            VisibilityScope::Workspace => {
                return Err(EngineError::InvalidVisibilityPromotion {
                    function_id: id.to_string(),
                    target: target.as_str().to_owned(),
                    reason: "workspace promotion requires a workspace id".to_owned(),
                });
            }
            _ => {
                return Err(EngineError::InvalidVisibilityPromotion {
                    function_id: id.to_string(),
                    target: target.as_str().to_owned(),
                    reason: "only workspace and system promotion are supported".to_owned(),
                });
            }
        }

        updated.revision = updated.revision.next();
        let revision = updated.revision;
        let subject = function_change_subject(&updated);
        self.record_change(CatalogChangeKind::VisibilityChanged, subject)?;
        self.functions
            .get_mut(id)
            .expect("function exists after immutable lookup")
            .definition = updated;
        Ok(revision)
    }

    /// Register or update a trigger type.
    pub fn register_trigger_type(
        &mut self,
        definition: TriggerTypeDefinition,
        volatile: bool,
    ) -> Result<()> {
        if self.worker(&definition.owner_worker).is_none() {
            return Err(EngineError::NotFound {
                kind: "worker",
                id: definition.owner_worker.to_string(),
            });
        }

        let kind = if let Some(existing) = self.trigger_types.get(&definition.id) {
            if existing.definition.owner_worker != definition.owner_worker {
                return Err(EngineError::OwnerMismatch {
                    kind: "trigger_type",
                    id: definition.id.to_string(),
                    owner: existing.definition.owner_worker.to_string(),
                    attempted_owner: definition.owner_worker.to_string(),
                });
            }
            CatalogChangeKind::TriggerTypeUpdated
        } else {
            CatalogChangeKind::TriggerTypeRegistered
        };
        let subject = trigger_type_change_subject(&definition);
        self.record_change(kind, subject)?;
        let _ = self.trigger_types.insert(
            definition.id.clone(),
            TriggerTypeEntry {
                definition,
                volatile,
            },
        );
        Ok(())
    }

    /// Inspect a trigger type.
    pub fn inspect_trigger_type(&self, id: &TriggerTypeId) -> Result<TriggerTypeDefinition> {
        self.trigger_types
            .get(id)
            .map(|entry| entry.definition.clone())
            .ok_or_else(|| EngineError::NotFound {
                kind: "trigger_type",
                id: id.to_string(),
            })
    }

    /// Register or update a trigger.
    pub fn register_trigger(
        &mut self,
        mut definition: TriggerDefinition,
        volatile: bool,
    ) -> Result<TriggerRevision> {
        if self.worker(&definition.owner_worker).is_none() {
            return Err(EngineError::NotFound {
                kind: "worker",
                id: definition.owner_worker.to_string(),
            });
        }
        let trigger_type = self
            .trigger_types
            .get(&definition.trigger_type)
            .ok_or_else(|| EngineError::NotFound {
                kind: "trigger_type",
                id: definition.trigger_type.to_string(),
            })?;
        let function = self
            .functions
            .get(&definition.target_function)
            .ok_or_else(|| EngineError::NotFound {
                kind: "function",
                id: definition.target_function.to_string(),
            })?;
        policy::validate_trigger_registration(
            &definition,
            &trigger_type.definition,
            &function.definition,
        )?;

        let kind = if let Some(existing) = self.triggers.get(&definition.id) {
            if existing.definition.owner_worker != definition.owner_worker {
                return Err(EngineError::OwnerMismatch {
                    kind: "trigger",
                    id: definition.id.to_string(),
                    owner: existing.definition.owner_worker.to_string(),
                    attempted_owner: definition.owner_worker.to_string(),
                });
            }
            definition.revision = existing.definition.revision.next();
            CatalogChangeKind::TriggerUpdated
        } else {
            definition.revision = TriggerRevision(1);
            CatalogChangeKind::TriggerRegistered
        };
        let revision = definition.revision;
        let subject = trigger_change_subject(&definition);
        self.record_change(kind, subject)?;
        let _ = self.triggers.insert(
            definition.id.clone(),
            TriggerEntry {
                definition,
                volatile,
            },
        );
        Ok(revision)
    }

    /// Inspect a trigger.
    pub fn inspect_trigger(&self, id: &TriggerId) -> Result<TriggerDefinition> {
        self.triggers
            .get(id)
            .map(|entry| entry.definition.clone())
            .ok_or_else(|| EngineError::NotFound {
                kind: "trigger",
                id: id.to_string(),
            })
    }

    /// Unregister a trigger owned by a worker.
    pub fn unregister_trigger(&mut self, id: &TriggerId, owner_worker: &WorkerId) -> Result<bool> {
        let Some(entry) = self.triggers.get(id) else {
            return Ok(false);
        };
        if &entry.definition.owner_worker != owner_worker {
            return Err(EngineError::OwnerMismatch {
                kind: "trigger",
                id: id.to_string(),
                owner: entry.definition.owner_worker.to_string(),
                attempted_owner: owner_worker.to_string(),
            });
        }
        let subject = trigger_change_subject(&entry.definition);
        self.record_change(CatalogChangeKind::TriggerUnregistered, subject)?;
        let _ = self.triggers.remove(id);
        Ok(true)
    }

    /// List triggers in deterministic order.
    #[must_use]
    pub fn triggers(&self) -> Vec<TriggerDefinition> {
        self.triggers
            .values()
            .map(|entry| entry.definition.clone())
            .collect()
    }

    /// Discover functions.
    #[must_use]
    pub fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition> {
        self.functions
            .values()
            .filter(|entry| {
                let function = &entry.definition;
                let can_include_internal = query
                    .actor
                    .as_ref()
                    .map(|actor| actor.actor_kind.is_admin_like())
                    .unwrap_or(false);
                if !(query.include_internal && can_include_internal)
                    && !policy::is_visible_to_actor(function, query.actor.as_ref())
                {
                    return false;
                }
                if let Some(visibility) = &query.visibility {
                    if &function.visibility != visibility {
                        return false;
                    }
                }
                if let Some(prefix) = &query.namespace_prefix {
                    if !function.id.as_str().starts_with(prefix) {
                        return false;
                    }
                }
                if let Some(effect) = query.effect_class {
                    if function.effect_class != effect {
                        return false;
                    }
                }
                if let Some(max_risk) = query.max_risk {
                    if function.risk_level > max_risk {
                        return false;
                    }
                }
                if let Some(health) = &query.health {
                    if &function.health != health {
                        return false;
                    }
                }
                if let Some(text) = &query.text {
                    let text = text.to_lowercase();
                    if !function.id.as_str().to_lowercase().contains(&text)
                        && !function.description.to_lowercase().contains(&text)
                        && !function
                            .tags
                            .iter()
                            .any(|tag| tag.to_lowercase().contains(&text))
                    {
                        return false;
                    }
                }
                true
            })
            .map(|entry| entry.definition.clone())
            .collect()
    }

    /// Invoke an in-process function synchronously.
    pub async fn invoke_sync(&mut self, invocation: Invocation) -> InvocationResult {
        match self.prepare_sync_invocation(invocation) {
            PreparedSyncInvocationDecision::Finished(result) => *result,
            PreparedSyncInvocationDecision::Execute(prepared) => {
                let result = prepared.handler.invoke(prepared.invocation.clone()).await;
                self.finish_prepared_sync_invocation(*prepared, result)
            }
        }
    }

    /// Prepare an in-process sync invocation without executing the handler.
    pub(in crate::engine) fn prepare_sync_invocation(
        &mut self,
        mut invocation: Invocation,
    ) -> PreparedSyncInvocationDecision {
        let Some(entry) = self.functions.get(&invocation.function_id) else {
            let worker_id = WorkerId::new("missing").expect("valid static id");
            let result = InvocationResult::error(
                &invocation,
                worker_id,
                FunctionRevision(0),
                self.revision,
                EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                },
            );
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                None,
            )));
        };
        let function = entry.definition.clone();
        let handler = entry.handler.clone();

        invocation.causal_context.catalog_revision = self.revision;

        if let Some(expected) = invocation.expected_function_revision {
            if expected != function.revision {
                let result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    EngineError::StaleFunctionRevision {
                        function_id: invocation.function_id.to_string(),
                        expected: expected.0,
                        actual: function.revision.0,
                    },
                );
                return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                    &invocation,
                    result,
                    None,
                )));
            }
        }

        if let Err(err) = policy::validate_invocation(&function, &invocation) {
            let result = InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                err,
            );
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                None,
            )));
        }

        let idempotency =
            match self.idempotency_lookup(&function, &invocation) {
                Ok(idempotency) => idempotency,
                Err(err) => {
                    let result = InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        err,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(&invocation, result, None),
                    ));
                }
            };

        if let Some(reservation) = &idempotency {
            match self.ledger.reserve_idempotency(reservation.clone()) {
                Ok(IdempotencyReservationOutcome::Reserved(_)) => {}
                Ok(IdempotencyReservationOutcome::Existing(existing)) => {
                    let result = self.result_for_existing_idempotency(
                        &function,
                        &invocation,
                        &existing,
                        &reservation.payload_fingerprint,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(
                            &invocation,
                            result,
                            Some(existing.key.scope.clone()),
                        ),
                    ));
                }
                Err(err) => {
                    let result = InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        err,
                    );
                    return PreparedSyncInvocationDecision::Finished(Box::new(
                        self.finish_invocation(
                            &invocation,
                            result,
                            Some(reservation.key.scope.clone()),
                        ),
                    ));
                }
            }
        }

        if let Some(schema) = &function.request_schema {
            if let Err(err) =
                schema::validate_payload(&function.id, "request", schema, &invocation.payload)
            {
                let mut result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                );
                if let Some(reservation) = &idempotency
                    && let Some(completion_error) = self.complete_invocation_idempotency(
                        reservation,
                        &invocation,
                        &function,
                        &result,
                    )
                {
                    result = completion_error;
                }
                let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
                return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                    &invocation,
                    result,
                    idempotency_scope,
                )));
            }
        }

        let Some(handler) = handler else {
            let mut result = InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::NotRoutable {
                    function_id: invocation.function_id.to_string(),
                    reason: "no in-process handler".to_owned(),
                },
            );
            if let Some(reservation) = &idempotency
                && let Some(completion_error) = self.complete_invocation_idempotency(
                    reservation,
                    &invocation,
                    &function,
                    &result,
                )
            {
                result = completion_error;
            }
            let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
            return PreparedSyncInvocationDecision::Finished(Box::new(self.finish_invocation(
                &invocation,
                result,
                idempotency_scope,
            )));
        };

        PreparedSyncInvocationDecision::Execute(Box::new(PreparedSyncInvocation {
            invocation,
            function,
            handler,
            idempotency,
        }))
    }

    /// Finish an invocation whose handler already executed outside the catalog
    /// lock.
    pub(in crate::engine) fn finish_prepared_sync_invocation(
        &mut self,
        prepared: PreparedSyncInvocation,
        handler_result: Result<Value>,
    ) -> InvocationResult {
        let PreparedSyncInvocation {
            invocation,
            function,
            idempotency,
            ..
        } = prepared;
        let captured_revision = invocation.causal_context.catalog_revision;

        let result = match handler_result {
            Ok(value) => {
                if let Some(schema) = &function.response_schema {
                    if let Err(err) =
                        schema::validate_payload(&function.id, "response", schema, &value)
                    {
                        InvocationResult::error(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            captured_revision,
                            err,
                        )
                    } else {
                        InvocationResult::success(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            captured_revision,
                            value,
                        )
                    }
                } else {
                    InvocationResult::success(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        captured_revision,
                        value,
                    )
                }
            }
            Err(err) => InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                captured_revision,
                err,
            ),
        };

        if let Some(reservation) = &idempotency {
            if let Err(err) = self.ledger.complete_idempotency(
                &reservation.key,
                &invocation.id,
                StoredInvocationOutcome::from_result(&result),
            ) {
                let result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    captured_revision,
                    err,
                );
                return self.finish_invocation(
                    &invocation,
                    result,
                    Some(reservation.key.scope.clone()),
                );
            }
        }
        let idempotency_scope = idempotency.map(|reservation| reservation.key.scope);
        self.finish_invocation(&invocation, result, idempotency_scope)
    }

    fn result_for_existing_idempotency(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
        existing: &IdempotencyEntry,
        payload_fingerprint: &str,
    ) -> InvocationResult {
        if existing.payload_fingerprint != payload_fingerprint {
            return InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "same key was used with a different payload".to_owned(),
                },
            );
        }
        if existing.function_revision != function.revision {
            return InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "same key was used across function revisions".to_owned(),
                },
            );
        }

        match existing.status {
            IdempotencyStatus::InProgress => InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "previous attempt is still in progress".to_owned(),
                },
            ),
            IdempotencyStatus::Unknown => InvocationResult::error(
                invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::IdempotencyConflict {
                    function_id: function.id.to_string(),
                    key: existing.key.key.clone(),
                    reason: "previous attempt has unknown outcome".to_owned(),
                },
            ),
            IdempotencyStatus::Completed => match existing.replay_behavior {
                ReplayBehavior::ReturnPrevious => existing.outcome.as_ref().map_or_else(
                    || {
                        InvocationResult::error(
                            invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            EngineError::IdempotencyConflict {
                                function_id: function.id.to_string(),
                                key: existing.key.key.clone(),
                                reason: "completed reservation is missing outcome".to_owned(),
                            },
                        )
                    },
                    |outcome| {
                        outcome.to_replay_result(
                            invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            existing.first_invocation_id.clone(),
                        )
                    },
                ),
                ReplayBehavior::NoOp => InvocationResult::noop_replay(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    existing.first_invocation_id.clone(),
                ),
                ReplayBehavior::Reject => InvocationResult::error(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    EngineError::IdempotencyConflict {
                        function_id: function.id.to_string(),
                        key: existing.key.key.clone(),
                        reason: "duplicate key is configured to reject".to_owned(),
                    },
                ),
                ReplayBehavior::Compensate => InvocationResult::error(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    EngineError::IdempotencyConflict {
                        function_id: function.id.to_string(),
                        key: existing.key.key.clone(),
                        reason: "compensation replay is not executable in phase 1".to_owned(),
                    },
                ),
            },
        }
    }

    /// Reserve or replay an invocation idempotency key before executing work.
    pub(in crate::engine) fn begin_invocation_idempotency(
        &mut self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> InvocationIdempotencyDecision {
        let reservation = match self.idempotency_lookup(function, invocation) {
            Ok(Some(reservation)) => reservation,
            Ok(None) => return InvocationIdempotencyDecision::None,
            Err(err) => {
                return InvocationIdempotencyDecision::Finished {
                    result: InvocationResult::error(
                        invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        err,
                    ),
                    scope: None,
                };
            }
        };

        match self.ledger.reserve_idempotency(reservation.clone()) {
            Ok(IdempotencyReservationOutcome::Reserved(_)) => {
                InvocationIdempotencyDecision::Reserved(reservation)
            }
            Ok(IdempotencyReservationOutcome::Existing(existing)) => {
                InvocationIdempotencyDecision::Finished {
                    result: self.result_for_existing_idempotency(
                        function,
                        invocation,
                        &existing,
                        &reservation.payload_fingerprint,
                    ),
                    scope: Some(existing.key.scope.clone()),
                }
            }
            Err(err) => InvocationIdempotencyDecision::Finished {
                result: InvocationResult::error(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                ),
                scope: Some(reservation.key.scope),
            },
        }
    }

    /// Complete a reservation after executing work.
    pub(in crate::engine) fn complete_invocation_idempotency(
        &mut self,
        reservation: &IdempotencyReservation,
        invocation: &Invocation,
        function: &FunctionDefinition,
        result: &InvocationResult,
    ) -> Option<InvocationResult> {
        self.ledger
            .complete_idempotency(
                &reservation.key,
                &invocation.id,
                StoredInvocationOutcome::from_result(result),
            )
            .err()
            .map(|err| {
                InvocationResult::error(
                    invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                )
            })
    }

    fn finish_invocation(
        &mut self,
        invocation: &Invocation,
        result: InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
    ) -> InvocationResult {
        self.record_invocation_result(invocation, result, idempotency_scope)
    }

    /// Record an invocation result produced by a privileged host path.
    pub fn record_invocation_result(
        &mut self,
        invocation: &Invocation,
        result: InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
    ) -> InvocationResult {
        let record = InvocationRecord::from_result(invocation, &result, idempotency_scope);
        if let Err(err) = self.ledger.append_invocation(&record) {
            return InvocationResult::error(
                invocation,
                result.worker_id,
                result.function_revision,
                self.revision,
                err,
            );
        }
        self.invocations.push(record);
        result
    }

    fn idempotency_lookup(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<Option<IdempotencyReservation>> {
        let Some(contract) = &function.idempotency else {
            return Ok(None);
        };
        let Some(key) = &invocation.causal_context.idempotency_key else {
            return Ok(None);
        };
        if !matches!(
            contract.ledger_kind,
            LedgerKind::InMemory | LedgerKind::EngineLedger
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "idempotency ledger {:?} is not executable in phase 1",
                contract.ledger_kind
            )));
        }

        let scope = idempotency_scope_value(&contract.dedupe_scope, invocation)?;
        Ok(Some(IdempotencyReservation {
            key: IdempotencyKey {
                function_id: function.id.clone(),
                scope,
                key: key.clone(),
            },
            payload_fingerprint: payload_fingerprint(&invocation.payload),
            function_revision: function.revision,
            replay_behavior: contract.replay_behavior.clone(),
            invocation_id: invocation.id.clone(),
        }))
    }

    fn cleanup_owned_volatile(&mut self, worker_id: &WorkerId) -> Result<()> {
        let function_ids: Vec<FunctionId> = self
            .functions
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in function_ids {
            if let Some(entry) = self.functions.get(&id) {
                let subject = function_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::FunctionUnregistered, subject)?;
                let _ = self.functions.remove(&id);
            }
        }

        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            if let Some(entry) = self.triggers.get(&id) {
                let subject = trigger_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::TriggerUnregistered, subject)?;
                let _ = self.triggers.remove(&id);
            }
        }

        let trigger_type_ids: Vec<TriggerTypeId> = self
            .trigger_types
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_type_ids {
            if let Some(entry) = self.trigger_types.get(&id) {
                let subject = trigger_type_change_subject(&entry.definition);
                self.record_change(CatalogChangeKind::TriggerTypeUnregistered, subject)?;
                let _ = self.trigger_types.remove(&id);
            }
        }
        Ok(())
    }

    fn cleanup_triggers_targeting(&mut self, function_id: &FunctionId) -> Result<()> {
        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| &entry.definition.target_function == function_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            if let Some(removed) = self.triggers.get(&id) {
                let subject = trigger_change_subject(&removed.definition);
                self.record_change(CatalogChangeKind::TriggerUnregistered, subject)?;
                let _ = self.triggers.remove(&id);
            }
        }
        Ok(())
    }

    fn record_change(
        &mut self,
        kind: CatalogChangeKind,
        subject: CatalogChangeSubject,
    ) -> Result<()> {
        let before = self.revision;
        let after = self.revision.next();
        let change = CatalogChange {
            id: format!("catalog_change_{}_{}", after.0, uuid::Uuid::now_v7()),
            before,
            after,
            class: catalog_change_class(&kind),
            kind,
            subject_id: subject.id,
            subject_kind: subject.kind,
            visibility: subject.visibility,
            session_id: subject.session_id,
            workspace_id: subject.workspace_id,
            owner_worker: subject.owner_worker,
            timestamp: Utc::now(),
        };
        self.ledger.append_catalog_change(&change)?;
        self.revision = after;
        self.changes.push(change);
        Ok(())
    }
}

fn validate_worker_namespace_claims(definition: &WorkerDefinition) -> Result<()> {
    let claims_engine = definition
        .namespace_claims
        .iter()
        .any(|claim| claim == RESERVED_ENGINE_NAMESPACE);
    if !claims_engine {
        return Ok(());
    }
    if definition.id.as_str() == RESERVED_ENGINE_WORKER_ID
        && matches!(definition.kind, WorkerKind::System)
    {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(
        "reserved engine namespace can only be claimed by the system engine worker".to_owned(),
    ))
}

fn validate_reserved_function_namespace(definition: &FunctionDefinition) -> Result<()> {
    if definition.id.namespace() != RESERVED_ENGINE_NAMESPACE {
        return Ok(());
    }
    if definition.owner_worker.as_str() == RESERVED_ENGINE_WORKER_ID {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(
        "reserved engine namespace can only be registered by the system engine worker".to_owned(),
    ))
}

fn worker_change_subject(definition: &WorkerDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Worker,
        definition.visibility.clone(),
        &definition.provenance,
        None,
    )
}

fn function_change_subject(definition: &FunctionDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Function,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

fn trigger_type_change_subject(definition: &TriggerTypeDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::TriggerType,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

fn trigger_change_subject(definition: &TriggerDefinition) -> CatalogChangeSubject {
    provenance_subject(
        definition.id.to_string(),
        CatalogSubjectKind::Trigger,
        definition.visibility.clone(),
        &definition.provenance,
        Some(definition.owner_worker.clone()),
    )
}

fn provenance_subject(
    id: String,
    kind: CatalogSubjectKind,
    visibility: VisibilityScope,
    provenance: &Provenance,
    owner_worker: Option<WorkerId>,
) -> CatalogChangeSubject {
    CatalogChangeSubject {
        id,
        kind,
        visibility,
        session_id: provenance.session_id.clone(),
        workspace_id: provenance.workspace_id.clone(),
        owner_worker,
    }
}

fn catalog_change_class(kind: &CatalogChangeKind) -> CatalogChangeClass {
    match kind {
        CatalogChangeKind::WorkerRegistered
        | CatalogChangeKind::WorkerUpdated
        | CatalogChangeKind::WorkerUnregistered
        | CatalogChangeKind::FunctionRegistered
        | CatalogChangeKind::FunctionUnregistered => CatalogChangeClass::Availability,
        CatalogChangeKind::FunctionUpdated => CatalogChangeClass::Contract,
        CatalogChangeKind::TriggerTypeRegistered
        | CatalogChangeKind::TriggerTypeUpdated
        | CatalogChangeKind::TriggerTypeUnregistered
        | CatalogChangeKind::TriggerRegistered
        | CatalogChangeKind::TriggerUpdated
        | CatalogChangeKind::TriggerUnregistered => CatalogChangeClass::Trigger,
        CatalogChangeKind::VisibilityChanged => CatalogChangeClass::Visibility,
        CatalogChangeKind::HealthChanged => CatalogChangeClass::Health,
    }
}

impl Default for LiveCatalog {
    fn default() -> Self {
        Self::new()
    }
}

fn idempotency_scope_value(
    scope: &VisibilityScope,
    invocation: &Invocation,
) -> Result<IdempotencyScope> {
    match scope {
        VisibilityScope::Session => invocation
            .causal_context
            .session_id
            .clone()
            .map(|session| IdempotencyScope::new("session", session))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "session-scoped idempotency requires a session id".to_owned(),
                )
            }),
        VisibilityScope::Workspace => invocation
            .causal_context
            .workspace_id
            .clone()
            .map(|workspace| IdempotencyScope::new("workspace", workspace))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "workspace-scoped idempotency requires a workspace id".to_owned(),
                )
            }),
        VisibilityScope::System => Ok(IdempotencyScope::new("system", "system")),
        VisibilityScope::Agent => Ok(IdempotencyScope::new(
            "agent",
            invocation.causal_context.actor_id.to_string(),
        )),
        VisibilityScope::Client => Ok(IdempotencyScope::new(
            "client",
            invocation.causal_context.actor_id.to_string(),
        )),
        VisibilityScope::Worker => Ok(IdempotencyScope::new(
            "worker",
            invocation.causal_context.actor_id.to_string(),
        )),
        VisibilityScope::Admin => Ok(IdempotencyScope::new(
            "admin",
            invocation.causal_context.actor_id.to_string(),
        )),
        VisibilityScope::Internal => Ok(IdempotencyScope::new(
            "internal",
            invocation.causal_context.authority_grant_id.to_string(),
        )),
    }
}

fn payload_fingerprint(payload: &Value) -> String {
    let mut canonical = String::new();
    write_canonical_json(payload, &mut canonical);
    let digest = Sha256::digest(canonical.as_bytes());
    hex::encode(digest)
}

fn write_canonical_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => out.push_str(&value.to_string()),
        Value::String(value) => {
            let encoded = serde_json::to_string(value).expect("string serialization cannot fail");
            out.push_str(&encoded);
        }
        Value::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_canonical_json(value, out);
            }
            out.push(']');
        }
        Value::Object(values) => {
            out.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort();
            for (index, key) in keys.into_iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let encoded = serde_json::to_string(key).expect("string serialization cannot fail");
                out.push_str(&encoded);
                out.push(':');
                write_canonical_json(
                    values.get(key).expect("key was collected from this object"),
                    out,
                );
            }
            out.push('}');
        }
    }
}
