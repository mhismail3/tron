//! In-memory live catalog registry.
//!
//! Every entry couples one canonical function definition to its required
//! executable handler. The registry cannot represent an advertised-but-inert
//! function.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyEntry, InMemoryEngineLedgerStore,
};
use crate::engine::invocation::model::{InProcessFunctionHandler, InvocationRecord};
use crate::engine::kernel::errors::Result;
use crate::engine::kernel::ids::FunctionId;
use crate::engine::kernel::types::{CatalogRevision, FunctionDefinition};

mod idempotency;
mod invocation;
mod registration;
mod search;

pub(in crate::engine) use invocation::{PreparedSyncInvocation, PreparedSyncInvocationDecision};

const RESERVED_ENGINE_NAMESPACE: &str = "engine";
const RESERVED_ENGINE_WORKER_ID: &str = "engine";

struct FunctionEntry {
    definition: FunctionDefinition,
    handler: Arc<dyn InProcessFunctionHandler>,
}

/// In-memory live catalog.
pub struct LiveCatalog {
    revision: CatalogRevision,
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
