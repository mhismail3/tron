//! Worker, function, trigger, and discovery registration methods.

use std::sync::Arc;

use crate::engine::catalog::discovery::ActorContext;
use crate::engine::invocation::model::InProcessFunctionHandler;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::policy;
use crate::engine::kernel::types::{
    CatalogChangeKind, CatalogRevision, FunctionDefinition, FunctionRevision, VisibilityScope,
    WorkerDefinition, WorkerKind, WorkerRevision,
};

use super::catalog_changes::{function_change_subject, worker_change_subject};
use super::{
    FunctionEntry, LiveCatalog, RESERVED_ENGINE_NAMESPACE, RESERVED_ENGINE_WORKER_ID, WorkerEntry,
};

impl LiveCatalog {
    /// Restore the monotonic catalog revision from durable change history.
    ///
    /// Callable definitions are rebuilt by their fixed bootstrap or canonical
    /// worker bundles; the ledger never owns a second catalog definition plane.
    pub(in crate::engine) fn hydrate_catalog_revision_from_ledger(&mut self) -> Result<()> {
        let changes = self.ledger.list_catalog_changes()?;
        self.revision = changes
            .iter()
            .map(|change| change.after)
            .max()
            .unwrap_or(CatalogRevision(0));

        Ok(())
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
