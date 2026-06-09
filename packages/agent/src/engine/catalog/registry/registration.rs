//! Worker, function, trigger, and discovery registration methods.

use std::collections::BTreeSet;
use std::sync::Arc;

use crate::engine::catalog::discovery::ActorContext;
use crate::engine::invocation::model::InProcessFunctionHandler;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use crate::engine::kernel::policy;
use crate::engine::kernel::types::{
    CatalogChangeKind, CatalogRevision, FunctionDefinition, FunctionHealth, FunctionRevision,
    TriggerDefinition, TriggerRevision, TriggerTypeDefinition, VisibilityScope, WorkerDefinition,
    WorkerKind, WorkerLifecycleState, WorkerRevision,
};

use super::catalog_changes::{
    function_change_subject, trigger_change_subject, trigger_type_change_subject,
    worker_change_subject,
};
use super::{
    FunctionEntry, LiveCatalog, RESERVED_ENGINE_NAMESPACE, RESERVED_ENGINE_WORKER_ID, TriggerEntry,
    TriggerTypeEntry, WorkerEntry,
};

impl LiveCatalog {
    /// Hydrate durable external catalog entries from the ledger after a process
    /// restart. Handlers are intentionally not restored; external sockets must
    /// reconnect and re-register before their functions become healthy again.
    pub(in crate::engine) fn hydrate_durable_catalog_from_ledger(&mut self) -> Result<()> {
        let changes = self.ledger.list_catalog_changes()?;
        self.revision = changes
            .iter()
            .map(|change| change.after)
            .max()
            .unwrap_or(CatalogRevision(0));
        self.changes = changes;

        for mut worker in self.ledger.list_durable_worker_definitions()? {
            if worker.kind == WorkerKind::External {
                worker.lifecycle = WorkerLifecycleState::Stopped;
            }
            self.workers.insert(
                worker.id.clone(),
                WorkerEntry {
                    definition: worker,
                    volatile: false,
                },
            );
        }

        let worker_ids = self.workers.keys().cloned().collect::<BTreeSet<_>>();
        for mut function in self.ledger.list_durable_function_definitions()? {
            if !worker_ids.contains(&function.owner_worker) {
                continue;
            }
            function.health = FunctionHealth::Unhealthy;
            self.functions.insert(
                function.id.clone(),
                FunctionEntry {
                    definition: function,
                    handler: None,
                    volatile: false,
                },
            );
        }
        Ok(())
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
        if !volatile && definition.kind == WorkerKind::External {
            self.ledger.upsert_durable_worker_definition(&definition)?;
        } else {
            self.ledger
                .remove_durable_worker_definition(&definition.id)?;
        }
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
        self.ledger.remove_durable_worker_definition(id)?;
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
        let persist_durable_external = !volatile && owner.kind == WorkerKind::External;
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
        if persist_durable_external {
            self.ledger
                .upsert_durable_function_definition(&definition)?;
        } else {
            self.ledger
                .remove_durable_function_definition(&definition.id)?;
        }
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
        self.ledger.remove_durable_function_definition(id)?;
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
