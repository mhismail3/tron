//! In-memory live catalog registry.

use std::collections::BTreeMap;
use std::sync::Arc;

use chrono::Utc;

use super::discovery::FunctionQuery;
use super::errors::{EngineError, Result};
use super::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use super::invocation::{InProcessFunctionHandler, Invocation, InvocationResult};
use super::policy;
use super::types::{
    CatalogChange, CatalogChangeKind, CatalogRevision, FunctionDefinition, FunctionRevision,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, WorkerDefinition, WorkerRevision,
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

/// In-memory live catalog.
pub struct LiveCatalog {
    revision: CatalogRevision,
    workers: BTreeMap<WorkerId, WorkerEntry>,
    functions: BTreeMap<FunctionId, FunctionEntry>,
    trigger_types: BTreeMap<TriggerTypeId, TriggerTypeEntry>,
    triggers: BTreeMap<TriggerId, TriggerEntry>,
    changes: Vec<CatalogChange>,
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
        let removed = self.functions.remove(id).expect("entry exists");
        self.record_change(
            CatalogChangeKind::FunctionUnregistered,
            id.to_string(),
            Some(removed.definition.owner_worker),
        );
        Ok(())
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
    pub async fn invoke_sync(&self, mut invocation: Invocation) -> InvocationResult {
        let Some(entry) = self.functions.get(&invocation.function_id) else {
            let worker_id = WorkerId::new("missing").expect("valid static id");
            return InvocationResult::error(
                &invocation,
                worker_id,
                FunctionRevision(0),
                self.revision,
                EngineError::NotFound {
                    kind: "function",
                    id: invocation.function_id.to_string(),
                },
            );
        };

        invocation.causal_context.catalog_revision = self.revision;

        if let Some(expected) = invocation.expected_function_revision {
            if expected != entry.definition.revision {
                return InvocationResult::error(
                    &invocation,
                    entry.definition.owner_worker.clone(),
                    entry.definition.revision,
                    self.revision,
                    EngineError::StaleFunctionRevision {
                        function_id: invocation.function_id.to_string(),
                        expected: expected.0,
                        actual: entry.definition.revision.0,
                    },
                );
            }
        }

        if let Err(err) = policy::validate_invocation(&entry.definition, &invocation) {
            return InvocationResult::error(
                &invocation,
                entry.definition.owner_worker.clone(),
                entry.definition.revision,
                self.revision,
                err,
            );
        }

        let Some(handler) = &entry.handler else {
            return InvocationResult::error(
                &invocation,
                entry.definition.owner_worker.clone(),
                entry.definition.revision,
                self.revision,
                EngineError::NotRoutable {
                    function_id: invocation.function_id.to_string(),
                    reason: "no in-process handler".to_owned(),
                },
            );
        };

        match handler.invoke(invocation.clone()).await {
            Ok(value) => InvocationResult::success(
                &invocation,
                entry.definition.owner_worker.clone(),
                entry.definition.revision,
                self.revision,
                value,
            ),
            Err(err) => InvocationResult::error(
                &invocation,
                entry.definition.owner_worker.clone(),
                entry.definition.revision,
                self.revision,
                err,
            ),
        }
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
