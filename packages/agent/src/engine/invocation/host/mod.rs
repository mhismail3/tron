//! Engine host, privileged transport functions, and ledgered invocation.
//!
//! `EngineHost` is the boundary future server/runtime services should use when
//! they need the live capability fabric. It keeps `engine::*` capabilities
//! visible as normal catalog functions while executing them through privileged
//! host code that cannot be replaced by ordinary workers.
//!
//! Submodules keep host responsibilities split by surface: bootstrap
//! construction and built-ins, handle constructors, catalog operations,
//! invocation orchestration, delegated/meta invocation, substrate-store methods,
//! shared invocation helpers, meta-function definitions, and the primitive
//! runtime host.

use std::any::Any;
use std::panic::AssertUnwindSafe;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use futures::FutureExt as _;
use serde_json::{Value, json};
use tokio::sync::{Mutex, MutexGuard};

use crate::engine::authority::compensation::{EngineCompensationRecord, compensation_record};
use crate::engine::authority::leases::{AcquireResourceLease, EngineResourceLease};
use crate::engine::catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
use crate::engine::catalog::registry::{
    InvocationIdempotencyDecision, LiveCatalog, PreparedSyncInvocation,
    PreparedSyncInvocationDecision,
};
use crate::engine::durability::ledger::{
    EngineLedgerStore, IdempotencyReservation, SqliteEngineLedgerStore, StoredEngineError,
};
use crate::engine::durability::queue::{
    EngineQueueAttemptRecord, EngineQueueItem, EnqueueInvocation,
};
use crate::engine::durability::streams::{
    EngineStreamPage, EngineStreamSubscription, PublishStreamEvent, StreamActorScope, StreamCursor,
};
use crate::engine::invocation::model::{
    CausalContext, InProcessFunctionHandler, Invocation, InvocationResult,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TriggerId, TriggerTypeId, WorkerId,
};
use crate::engine::kernel::types::{
    AuthorityRequirement, CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision,
    CompensationContract, DeliveryMode, EffectClass, FunctionDefinition, FunctionHealth,
    FunctionRevision, IdempotencyContract, Provenance, ResourceLeaseFailureBehavior,
    ResourceLeaseRequirement, RiskLevel, TriggerDefinition, TriggerRevision, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition, WorkerKind, WorkerRevision,
};
use crate::engine::kernel::{policy, schema};
use crate::engine::primitives;
use crate::engine::primitives::{
    PrimitiveStores, primitive_function_definitions, primitive_workers,
};

mod bootstrap;
mod catalog_handle;
mod handle;
mod invocation_handle;
mod invocation_support;
mod meta;
mod meta_invocation;
mod runtime_host;
mod substrate_handle;

use invocation_support::*;
use meta::*;
pub use meta::{CatalogWatchRequest, CatalogWatchResponse};

struct PreparedDelegatedInvocation {
    meta_invocation: Invocation,
    meta_function: FunctionDefinition,
    child: PreparedDelegatedChild,
}

enum PreparedDelegatedChild {
    Sync(PreparedSyncInvocationDecision),
}

enum PreparedDelegatedInvocationDecision {
    Execute(Box<PreparedDelegatedInvocation>),
    Finished(Box<InvocationResult>),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum InvocationRecordingPolicy {
    RecordAll,
    SkipRetryableQueueDeliveryFailure,
}

pub(in crate::engine) struct QueueTargetInvocation {
    pub result: InvocationResult,
    pub recorded_invocation: bool,
    pub resource_lease_ids: Vec<String>,
    pub compensation_status: Option<String>,
    pub compensation_id: Option<String>,
}

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
    /// Borrow the live catalog.
    #[must_use]
    pub fn catalog(&self) -> &LiveCatalog {
        &self.catalog
    }

    /// Mutably borrow the live catalog for tests and bootstrap setup.
    pub fn catalog_mut(&mut self) -> &mut LiveCatalog {
        &mut self.catalog
    }

    /// Pull catalog changes visible to an actor after a cursor.
    pub fn watch_catalog(
        &self,
        actor: &ActorContext,
        request: CatalogWatchRequest,
    ) -> Result<CatalogWatchResponse> {
        let current_revision = self.catalog.revision();
        if request.after_revision > current_revision {
            return Ok(CatalogWatchResponse {
                changes: Vec::new(),
                current_revision,
                next_revision: current_revision,
                has_more: false,
            });
        }
        if request.limit == 0 {
            return Err(EngineError::PolicyViolation(
                "watch limit must be greater than zero".to_owned(),
            ));
        }

        let limit = request.limit.min(WATCH_MAX_LIMIT);
        let matching = self
            .catalog
            .ledger_catalog_changes()?
            .into_iter()
            .filter(|change| change.after > request.after_revision)
            .filter(|change| is_change_visible_to_actor(change, actor))
            .filter(|change| {
                request
                    .classes
                    .as_ref()
                    .map(|classes| classes.contains(&change.class))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .kinds
                    .as_ref()
                    .map(|kinds| kinds.contains(&change.kind))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .subject_prefix
                    .as_ref()
                    .map(|prefix| change.subject_id.starts_with(prefix))
                    .unwrap_or(true)
            })
            .filter(|change| {
                request
                    .owner_worker
                    .as_ref()
                    .map(|owner| change.owner_worker.as_ref() == Some(owner))
                    .unwrap_or(true)
            })
            .collect::<Vec<_>>();
        let has_more = matching.len() > limit;
        let changes = matching.into_iter().take(limit).collect::<Vec<_>>();
        let next_revision = changes
            .last()
            .map(|change| change.after)
            .unwrap_or(request.after_revision);
        Ok(CatalogWatchResponse {
            changes,
            current_revision,
            next_revision,
            has_more,
        })
    }

    /// Invoke a function through the host.
    pub async fn invoke(&mut self, invocation: Invocation) -> InvocationResult {
        if invocation.function_id.namespace() != ENGINE_WORKER_ID {
            if is_host_dispatched_primitive_function(&invocation.function_id) {
                return self.invoke_sync_host_dispatched_primitive(invocation);
            }
            return self.catalog.invoke_sync(invocation).await;
        }

        match invocation.function_id.as_str() {
            DISCOVER_FUNCTION | INSPECT_FUNCTION | WATCH_FUNCTION | PROMOTE_FUNCTION => {
                self.invoke_sync_meta(invocation)
            }
            INVOKE_FUNCTION => self.invoke_delegated(invocation).await,
            _ => self.catalog.invoke_sync(invocation).await,
        }
    }
}

impl EngineHost {
    fn storage_runtime(&self) -> Result<crate::shared::storage::StorageRuntime> {
        let Some(path) = &self.storage_path else {
            return Err(EngineError::PolicyViolation(
                "storage primitives require a SQLite-backed engine host".to_owned(),
            ));
        };
        Ok(crate::shared::storage::StorageRuntime::new(path.clone()))
    }
}

fn storage_error(error: anyhow::Error) -> EngineError {
    EngineError::HandlerFailed(format!("storage primitive failed: {error:#}"))
}
