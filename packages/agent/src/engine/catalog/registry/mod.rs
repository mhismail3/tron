//! In-memory live catalog registry.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, InMemoryEngineLedgerStore,
};
use crate::engine::invocation::model::{InProcessFunctionHandler, InvocationRecord};
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, WorkerDefinition,
};

mod catalog_changes;
mod cleanup;
mod idempotency;
mod invocation;
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

/// In-memory live catalog.
pub struct LiveCatalog {
    revision: CatalogRevision,
    workers: BTreeMap<WorkerId, WorkerEntry>,
    functions: BTreeMap<FunctionId, FunctionEntry>,
    ledger: Box<dyn EngineLedgerStore>,
}

impl LiveCatalog {
    /// Create an empty live catalog.
    #[must_use]
    pub(in crate::engine) fn new() -> Self {
        Self::with_ledger_store(Box::new(InMemoryEngineLedgerStore::new()))
    }

    /// Create an empty live catalog using a caller-supplied ledger store.
    #[must_use]
    pub(in crate::engine) fn with_ledger_store(ledger: Box<dyn EngineLedgerStore>) -> Self {
        Self {
            revision: CatalogRevision(0),
            workers: BTreeMap::new(),
            functions: BTreeMap::new(),
            ledger,
        }
    }

    /// Current catalog revision.
    #[must_use]
    pub fn revision(&self) -> CatalogRevision {
        self.revision
    }

    /// All durable invocation records in append order for deep engine tests.
    #[cfg(test)]
    pub(in crate::engine) fn ledger_invocations(&self) -> Result<Vec<InvocationRecord>> {
        self.ledger.list_invocations()
    }

    /// Durable catalog changes recorded by the engine ledger for crate unit tests.
    #[cfg(test)]
    pub(in crate::engine) fn catalog_changes_after(
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

    /// Durable idempotency entries that explain one session.
    pub fn ledger_idempotency_by_session(&self, session_id: &str) -> Result<Vec<IdempotencyEntry>> {
        self.ledger.list_idempotency_by_session(session_id)
    }
}

impl Default for LiveCatalog {
    fn default() -> Self {
        Self::new()
    }
}
