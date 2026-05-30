//! In-memory live catalog registry.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex as StdMutex};

use chrono::Utc;

use super::discovery::{ActorContext, FunctionQuery};
use super::errors::{EngineError, Result};
use super::grants::{EngineGrantLifecycle, EngineGrantStoreBackend, InMemoryEngineGrantStore};
use super::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use super::invocation::{InProcessFunctionHandler, InvocationRecord};
use super::ledger::{EngineLedgerStore, InMemoryEngineLedgerStore};
use super::policy;
use super::types::{
    CatalogChange, CatalogChangeKind, CatalogRevision, FunctionDefinition, FunctionRevision,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerRevision,
};

mod catalog_changes;
mod invocation;
mod output_contract;

use catalog_changes::{
    function_change_subject, trigger_change_subject, trigger_type_change_subject,
    worker_change_subject,
};
pub(in crate::engine) use invocation::{
    InvocationIdempotencyDecision, PreparedSyncInvocation, PreparedSyncInvocationDecision,
};
use output_contract::output_contract_resource_kinds;

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
    grants: Arc<StdMutex<EngineGrantStoreBackend>>,
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
            grants: Arc::new(StdMutex::new(EngineGrantStoreBackend::InMemory(
                InMemoryEngineGrantStore::new(),
            ))),
        }
    }

    /// Use a caller-supplied grant store for invocation authorization.
    pub(in crate::engine) fn set_grant_store(
        &mut self,
        grants: Arc<StdMutex<EngineGrantStoreBackend>>,
    ) {
        self.grants = grants;
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
        self.validate_worker_grant(&definition)?;
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
        self.validate_function_worker_grant(&definition, owner)?;
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

    /// List trigger types in deterministic order.
    #[must_use]
    pub fn trigger_types(&self) -> Vec<TriggerTypeDefinition> {
        self.trigger_types
            .values()
            .map(|entry| entry.definition.clone())
            .collect()
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
                    let tokens = search_tokens(text);
                    if !tokens.is_empty() {
                        let haystack = function_search_haystack(function);
                        if !tokens.iter().all(|token| haystack.contains(token)) {
                            return false;
                        }
                    }
                }
                true
            })
            .map(|entry| entry.definition.clone())
            .collect()
    }

    fn validate_worker_grant(&self, definition: &WorkerDefinition) -> Result<()> {
        let grants = self
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?;
        let grant = grants
            .inspect(&definition.authority_grant)?
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "worker {} authority grant {} not found",
                    definition.id, definition.authority_grant
                ))
            })?;
        if grant.lifecycle != EngineGrantLifecycle::Active {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} authority grant {} is not active",
                definition.id, definition.authority_grant
            )));
        }
        if let Some(expires_at) = grant.expires_at
            && expires_at <= Utc::now()
        {
            return Err(EngineError::PolicyViolation(format!(
                "worker {} authority grant {} is expired",
                definition.id, definition.authority_grant
            )));
        }
        for namespace in &definition.namespace_claims {
            if !allows_item(&grant.allowed_namespaces, namespace) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker {} namespace {namespace} exceeds authority grant {}",
                    definition.id, definition.authority_grant
                )));
            }
        }
        Ok(())
    }

    fn validate_function_worker_grant(
        &self,
        definition: &FunctionDefinition,
        owner: &WorkerDefinition,
    ) -> Result<()> {
        let grants = self
            .grants
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?;
        let grant = grants.inspect(&owner.authority_grant)?.ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "function {} worker grant {} not found",
                definition.id, owner.authority_grant
            ))
        })?;
        if grant.lifecycle != EngineGrantLifecycle::Active {
            return Err(EngineError::PolicyViolation(format!(
                "function {} worker grant {} is not active",
                definition.id, owner.authority_grant
            )));
        }
        if definition.risk_level > grant.max_risk {
            return Err(EngineError::PolicyViolation(format!(
                "function {} risk {:?} exceeds worker grant {} max risk {:?}",
                definition.id, definition.risk_level, owner.authority_grant, grant.max_risk
            )));
        }
        if !allows_item(&grant.allowed_capabilities, definition.id.as_str())
            && !allows_item(&grant.allowed_namespaces, definition.id.namespace())
        {
            return Err(EngineError::PolicyViolation(format!(
                "function {} exceeds worker grant {} capabilities",
                definition.id, owner.authority_grant
            )));
        }
        for scope in &definition.required_authority.scopes {
            if !allows_item(&grant.allowed_authority_scopes, scope) {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} required authority {scope} exceeds worker grant {}",
                    definition.id, owner.authority_grant
                )));
            }
        }
        for kind in output_contract_resource_kinds(&definition.output_contract) {
            if kind != "*" && !allows_item(&grant.allowed_resource_kinds, &kind) {
                return Err(EngineError::PolicyViolation(format!(
                    "function {} output resource kind {kind} exceeds worker grant {}",
                    definition.id, owner.authority_grant
                )));
            }
        }
        Ok(())
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

fn search_tokens(text: &str) -> Vec<String> {
    normalize_search_text(text)
        .split_whitespace()
        .map(ToOwned::to_owned)
        .collect()
}

fn function_search_haystack(function: &FunctionDefinition) -> String {
    let mut parts = vec![
        function.id.as_str().to_owned(),
        normalize_search_text(function.id.as_str()),
        function.description.clone(),
    ];
    parts.extend(function.tags.iter().cloned());
    if !function.metadata.is_null()
        && let Ok(metadata) = serde_json::to_string(&function.metadata)
    {
        parts.push(metadata);
    }
    normalize_search_text(&parts.join(" "))
}

fn normalize_search_text(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect()
}

impl Default for LiveCatalog {
    fn default() -> Self {
        Self::new()
    }
}

fn allows_item(allowed: &[String], value: &str) -> bool {
    allowed.iter().any(|item| item == "*" || item == value)
}
