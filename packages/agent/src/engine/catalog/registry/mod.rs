//! In-memory live catalog registry.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex as StdMutex};

use crate::engine::authority::grants::{EngineGrantStoreBackend, InMemoryEngineGrantStore};
use crate::engine::durability::ledger::{EngineLedgerStore, InMemoryEngineLedgerStore};
use crate::engine::invocation::model::{InProcessFunctionHandler, InvocationRecord};
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, TriggerId, TriggerTypeId, WorkerId};
use crate::engine::kernel::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, TriggerDefinition, TriggerTypeDefinition,
    WorkerDefinition,
};

mod authorization;
mod catalog_changes;
mod cleanup;
mod idempotency;
mod invocation;
mod output_contract;
mod registration;
mod search;

pub(in crate::engine) use idempotency::InvocationIdempotencyDecision;
pub(in crate::engine) use invocation::{PreparedSyncInvocation, PreparedSyncInvocationDecision};

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

    /// Durable invocation records for one session in append order.
    pub fn ledger_invocations_by_session(&self, session_id: &str) -> Result<Vec<InvocationRecord>> {
        self.ledger.list_invocations_by_session(session_id)
    }
}

impl Default for LiveCatalog {
    fn default() -> Self {
        Self::new()
    }
}
