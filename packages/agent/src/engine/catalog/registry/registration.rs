//! Function registration and inspection methods.

use std::sync::Arc;

use crate::engine::catalog::discovery::ActorContext;
use crate::engine::invocation::model::InProcessFunctionHandler;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::policy;
use crate::engine::kernel::types::{FunctionDefinition, FunctionRevision};

use super::{FunctionEntry, LiveCatalog, RESERVED_ENGINE_NAMESPACE, RESERVED_ENGINE_WORKER_ID};

impl LiveCatalog {
    /// Restore the monotonic catalog revision from durable state.
    ///
    /// Callable definitions are rebuilt by their fixed bootstrap or canonical
    /// worker bundles; the ledger never owns a second catalog definition plane.
    pub(in crate::engine) fn hydrate_catalog_revision_from_ledger(&mut self) -> Result<()> {
        self.revision = self.ledger.catalog_revision()?;
        Ok(())
    }

    /// Register or update a function.
    pub fn register_function(
        &mut self,
        mut definition: FunctionDefinition,
        handler: Arc<dyn InProcessFunctionHandler>,
    ) -> Result<FunctionRevision> {
        validate_reserved_function_namespace(&definition)?;
        policy::validate_function_registration(&definition)?;

        if let Some(existing) = self.functions.get(&definition.id) {
            if existing.definition.owner_worker != definition.owner_worker {
                return Err(EngineError::OwnerMismatch {
                    kind: "function",
                    id: definition.id.to_string(),
                    owner: existing.definition.owner_worker.to_string(),
                    attempted_owner: definition.owner_worker.to_string(),
                });
            }
            definition.revision = existing.definition.revision.next();
        } else {
            definition.revision = FunctionRevision(1);
        }

        let revision = definition.revision;
        self.advance_revision()?;
        let _ = self.functions.insert(
            definition.id.clone(),
            FunctionEntry {
                definition,
                handler,
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
        actor: &ActorContext,
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
        self.advance_revision()?;
        let _ = self.functions.remove(id).expect("entry exists");
        Ok(())
    }

    fn advance_revision(&mut self) -> Result<()> {
        let next = self.revision.next();
        self.ledger.advance_catalog_revision(self.revision, next)?;
        self.revision = next;
        Ok(())
    }
}

fn validate_reserved_function_namespace(definition: &FunctionDefinition) -> Result<()> {
    if definition.id.namespace() != RESERVED_ENGINE_NAMESPACE {
        return Ok(());
    }
    if definition.owner_worker.as_str() == RESERVED_ENGINE_WORKER_ID {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(
        "reserved engine namespace can only be registered by the engine owner".to_owned(),
    ))
}
