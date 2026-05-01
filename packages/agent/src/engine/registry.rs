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
use super::policy;
use super::schema;
use super::types::{
    CatalogChange, CatalogChangeKind, CatalogRevision, FunctionDefinition, FunctionRevision,
    LedgerKind, ReplayBehavior, TriggerDefinition, TriggerRevision, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerRevision,
};

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

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct IdempotencyScopeKey {
    function_id: FunctionId,
    scope: &'static str,
    scope_value: String,
    key: String,
}

#[derive(Clone, Debug)]
struct IdempotencyEntry {
    payload_fingerprint: String,
    function_revision: FunctionRevision,
    result: InvocationResult,
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
    idempotency: BTreeMap<IdempotencyScopeKey, IdempotencyEntry>,
}

impl LiveCatalog {
    /// Create an empty live catalog.
    #[must_use]
    pub fn new() -> Self {
        Self {
            revision: CatalogRevision(0),
            workers: BTreeMap::new(),
            functions: BTreeMap::new(),
            trigger_types: BTreeMap::new(),
            triggers: BTreeMap::new(),
            changes: Vec::new(),
            invocations: Vec::new(),
            idempotency: BTreeMap::new(),
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

    /// Register or update a worker.
    pub fn register_worker(
        &mut self,
        mut definition: WorkerDefinition,
        volatile: bool,
    ) -> Result<WorkerRevision> {
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
        let subject_id = definition.id.to_string();
        let _ = self.workers.insert(
            definition.id.clone(),
            WorkerEntry {
                definition,
                volatile,
            },
        );
        self.record_change(kind, subject_id, None);
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
        let _ = self.workers.remove(id);
        self.cleanup_owned_volatile(id);
        self.record_change(CatalogChangeKind::WorkerUnregistered, id.to_string(), None);
        Ok(())
    }

    /// Register or update a function.
    pub fn register_function(
        &mut self,
        mut definition: FunctionDefinition,
        handler: Option<Arc<dyn InProcessFunctionHandler>>,
        volatile: bool,
    ) -> Result<FunctionRevision> {
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
        let subject_id = definition.id.to_string();
        let owner_worker = definition.owner_worker.clone();
        let _ = self.functions.insert(
            definition.id.clone(),
            FunctionEntry {
                definition,
                handler,
                volatile,
            },
        );
        self.record_change(kind, subject_id, Some(owner_worker));
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
        self.cleanup_triggers_targeting(id);
        let removed = self.functions.remove(id).expect("entry exists");
        self.record_change(
            CatalogChangeKind::FunctionUnregistered,
            id.to_string(),
            Some(removed.definition.owner_worker),
        );
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
        let Some(entry) = self.functions.get_mut(id) else {
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

        match target {
            VisibilityScope::Workspace if workspace_id.is_some() => {
                entry.definition.visibility = VisibilityScope::Workspace;
                entry.definition.provenance.session_id = None;
                entry.definition.provenance.workspace_id = workspace_id;
            }
            VisibilityScope::System => {
                entry.definition.visibility = VisibilityScope::System;
                entry.definition.provenance.session_id = None;
                entry.definition.provenance.workspace_id = None;
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

        entry.definition.revision = entry.definition.revision.next();
        let revision = entry.definition.revision;
        let owner_worker = entry.definition.owner_worker.clone();
        self.record_change(
            CatalogChangeKind::VisibilityChanged,
            id.to_string(),
            Some(owner_worker),
        );
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
        let subject_id = definition.id.to_string();
        let owner_worker = definition.owner_worker.clone();
        let _ = self.trigger_types.insert(
            definition.id.clone(),
            TriggerTypeEntry {
                definition,
                volatile,
            },
        );
        self.record_change(kind, subject_id, Some(owner_worker));
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
        let subject_id = definition.id.to_string();
        let owner_worker = definition.owner_worker.clone();
        let _ = self.triggers.insert(
            definition.id.clone(),
            TriggerEntry {
                definition,
                volatile,
            },
        );
        self.record_change(kind, subject_id, Some(owner_worker));
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
    pub async fn invoke_sync(&mut self, mut invocation: Invocation) -> InvocationResult {
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
            return self.finish_invocation(&invocation, result);
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
                return self.finish_invocation(&invocation, result);
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
            return self.finish_invocation(&invocation, result);
        }

        if let Some(schema) = &function.request_schema {
            if let Err(err) =
                schema::validate_payload(&function.id, "request", schema, &invocation.payload)
            {
                let result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                );
                return self.finish_invocation(&invocation, result);
            }
        }

        let idempotency = match self.idempotency_lookup(&function, &invocation) {
            Ok(idempotency) => idempotency,
            Err(err) => {
                let result = InvocationResult::error(
                    &invocation,
                    function.owner_worker.clone(),
                    function.revision,
                    self.revision,
                    err,
                );
                return self.finish_invocation(&invocation, result);
            }
        };
        if let Some((key, payload_fingerprint, replay_behavior)) = &idempotency {
            if let Some(existing) = self.idempotency.get(key) {
                let result = if existing.payload_fingerprint != *payload_fingerprint {
                    InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        EngineError::IdempotencyConflict {
                            function_id: function.id.to_string(),
                            key: key.key.clone(),
                            reason: "same key was used with a different payload".to_owned(),
                        },
                    )
                } else if existing.function_revision != function.revision {
                    InvocationResult::error(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        EngineError::IdempotencyConflict {
                            function_id: function.id.to_string(),
                            key: key.key.clone(),
                            reason: "same key was used across function revisions".to_owned(),
                        },
                    )
                } else {
                    match replay_behavior {
                        ReplayBehavior::ReturnPrevious => {
                            InvocationResult::replay_previous(&invocation, &existing.result)
                        }
                        ReplayBehavior::NoOp => InvocationResult::noop_replay(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            existing.result.invocation_id.clone(),
                        ),
                        ReplayBehavior::Reject => InvocationResult::error(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            EngineError::IdempotencyConflict {
                                function_id: function.id.to_string(),
                                key: key.key.clone(),
                                reason: "duplicate key is configured to reject".to_owned(),
                            },
                        ),
                        ReplayBehavior::Compensate => InvocationResult::error(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            EngineError::IdempotencyConflict {
                                function_id: function.id.to_string(),
                                key: key.key.clone(),
                                reason: "compensation replay is not executable in phase 1"
                                    .to_owned(),
                            },
                        ),
                    }
                };
                return self.finish_invocation(&invocation, result);
            }
        }

        let Some(handler) = handler else {
            let result = InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                EngineError::NotRoutable {
                    function_id: invocation.function_id.to_string(),
                    reason: "no in-process handler".to_owned(),
                },
            );
            return self.finish_invocation(&invocation, result);
        };

        let result = match handler.invoke(invocation.clone()).await {
            Ok(value) => {
                if let Some(schema) = &function.response_schema {
                    if let Err(err) =
                        schema::validate_payload(&function.id, "response", schema, &value)
                    {
                        InvocationResult::error(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            err,
                        )
                    } else {
                        InvocationResult::success(
                            &invocation,
                            function.owner_worker.clone(),
                            function.revision,
                            self.revision,
                            value,
                        )
                    }
                } else {
                    InvocationResult::success(
                        &invocation,
                        function.owner_worker.clone(),
                        function.revision,
                        self.revision,
                        value,
                    )
                }
            }
            Err(err) => InvocationResult::error(
                &invocation,
                function.owner_worker.clone(),
                function.revision,
                self.revision,
                err,
            ),
        };

        if let Some((key, payload_fingerprint, _)) = idempotency {
            if function
                .idempotency
                .as_ref()
                .map(|contract| contract.ledger_kind == LedgerKind::InMemory)
                .unwrap_or(false)
            {
                let _ = self.idempotency.insert(
                    key,
                    IdempotencyEntry {
                        payload_fingerprint,
                        function_revision: function.revision,
                        result: result.clone(),
                    },
                );
            }
        }
        self.finish_invocation(&invocation, result)
    }

    fn finish_invocation(
        &mut self,
        invocation: &Invocation,
        result: InvocationResult,
    ) -> InvocationResult {
        self.invocations
            .push(InvocationRecord::from_result(invocation, &result));
        result
    }

    fn idempotency_lookup(
        &self,
        function: &FunctionDefinition,
        invocation: &Invocation,
    ) -> Result<Option<(IdempotencyScopeKey, String, ReplayBehavior)>> {
        let Some(contract) = &function.idempotency else {
            return Ok(None);
        };
        let Some(key) = &invocation.causal_context.idempotency_key else {
            return Ok(None);
        };
        if contract.ledger_kind != LedgerKind::InMemory {
            return Err(EngineError::PolicyViolation(format!(
                "idempotency ledger {:?} is not executable in phase 1",
                contract.ledger_kind
            )));
        }

        let (scope, scope_value) = idempotency_scope_value(&contract.dedupe_scope, invocation)?;
        Ok(Some((
            IdempotencyScopeKey {
                function_id: function.id.clone(),
                scope,
                scope_value,
                key: key.clone(),
            },
            payload_fingerprint(&invocation.payload),
            contract.replay_behavior.clone(),
        )))
    }

    fn cleanup_owned_volatile(&mut self, worker_id: &WorkerId) {
        let function_ids: Vec<FunctionId> = self
            .functions
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in function_ids {
            let _ = self.functions.remove(&id);
            self.record_change(
                CatalogChangeKind::FunctionUnregistered,
                id.to_string(),
                Some(worker_id.clone()),
            );
        }

        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            let _ = self.triggers.remove(&id);
            self.record_change(
                CatalogChangeKind::TriggerUnregistered,
                id.to_string(),
                Some(worker_id.clone()),
            );
        }

        let trigger_type_ids: Vec<TriggerTypeId> = self
            .trigger_types
            .iter()
            .filter(|(_, entry)| entry.volatile && &entry.definition.owner_worker == worker_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_type_ids {
            let _ = self.trigger_types.remove(&id);
            self.record_change(
                CatalogChangeKind::TriggerTypeUnregistered,
                id.to_string(),
                Some(worker_id.clone()),
            );
        }
    }

    fn cleanup_triggers_targeting(&mut self, function_id: &FunctionId) {
        let trigger_ids: Vec<TriggerId> = self
            .triggers
            .iter()
            .filter(|(_, entry)| &entry.definition.target_function == function_id)
            .map(|(id, _)| id.clone())
            .collect();
        for id in trigger_ids {
            if let Some(removed) = self.triggers.remove(&id) {
                self.record_change(
                    CatalogChangeKind::TriggerUnregistered,
                    id.to_string(),
                    Some(removed.definition.owner_worker),
                );
            }
        }
    }

    fn record_change(
        &mut self,
        kind: CatalogChangeKind,
        subject_id: String,
        owner_worker: Option<WorkerId>,
    ) {
        let before = self.revision;
        self.revision = self.revision.next();
        let after = self.revision;
        self.changes.push(CatalogChange {
            id: format!("catalog_change_{}", after.0),
            before,
            after,
            kind,
            subject_id,
            owner_worker,
            timestamp: Utc::now(),
        });
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
) -> Result<(&'static str, String)> {
    match scope {
        VisibilityScope::Session => invocation
            .causal_context
            .session_id
            .clone()
            .map(|session| ("session", session))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "session-scoped idempotency requires a session id".to_owned(),
                )
            }),
        VisibilityScope::Workspace => invocation
            .causal_context
            .workspace_id
            .clone()
            .map(|workspace| ("workspace", workspace))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "workspace-scoped idempotency requires a workspace id".to_owned(),
                )
            }),
        VisibilityScope::System => Ok(("system", "system".to_owned())),
        VisibilityScope::Agent => Ok(("agent", invocation.causal_context.actor_id.to_string())),
        VisibilityScope::Client => Ok(("client", invocation.causal_context.actor_id.to_string())),
        VisibilityScope::Worker => Ok(("worker", invocation.causal_context.actor_id.to_string())),
        VisibilityScope::Admin => Ok(("admin", invocation.causal_context.actor_id.to_string())),
        VisibilityScope::Internal => Ok((
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
