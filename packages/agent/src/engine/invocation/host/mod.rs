//! Engine host and ledgered typed-function invocation.
//!
//! `EngineHostHandle` is the production boundary for server/runtime services
//! that need the live function fabric. `EngineHost` owns the function catalog
//! and direct durable state/stream stores. Raw host locking and catalog
//! borrowing are compiled only for crate unit tests.
//!
//! Submodules keep host responsibilities split by surface: bootstrap
//! construction, handle constructors, catalog operations, invocation
//! orchestration, and substrate-store methods.

use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::FutureExt as _;
use serde_json::Value;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use crate::engine::catalog::discovery::ActorContext;
use crate::engine::catalog::registry::{
    LiveCatalog, PreparedSyncInvocation, PreparedSyncInvocationDecision,
};
use crate::engine::durability::ledger::SqliteEngineLedgerStore;
use crate::engine::durability::streams::{
    EngineStreamPage, PublishStreamEvent, StreamActorScope, StreamCursor,
};
use crate::engine::invocation::model::{InProcessFunctionHandler, Invocation, InvocationResult};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::types::{CatalogRevision, FunctionDefinition, FunctionRevision};
use crate::engine::primitives::PrimitiveStores;

mod bootstrap;
mod catalog_handle;
mod handle;
mod invocation_handle;
mod substrate_handle;

/// Host for the in-process live capability engine.
pub struct EngineHost {
    catalog: LiveCatalog,
    primitives: PrimitiveStores,
    storage_path: Option<PathBuf>,
}

/// Cloneable owner for the live capability engine host.
#[derive(Clone)]
pub struct EngineHostHandle {
    inner: Arc<Mutex<EngineHost>>,
}

impl EngineHost {
    /// Borrow the live catalog for crate unit tests.
    #[cfg(test)]
    #[must_use]
    pub(crate) fn catalog(&self) -> &LiveCatalog {
        &self.catalog
    }

    /// Mutably borrow the live catalog for crate unit tests.
    #[cfg(test)]
    pub(crate) fn catalog_mut(&mut self) -> &mut LiveCatalog {
        &mut self.catalog
    }
}

fn storage_error(error: anyhow::Error) -> EngineError {
    EngineError::HandlerFailed(format!("storage primitive failed: {error:#}"))
}
