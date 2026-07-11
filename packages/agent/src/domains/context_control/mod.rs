//! Context-control primitive for session context visibility and epoch changes.
//!
//! Context control owns durable `context_control_snapshot`,
//! `context_control_action`, `context_control_epoch`, `context_survivor`,
//! `context_exclusion`, and `context_policy_snapshot` resources. It exposes a
//! narrow first-party UI surface plus model-facing `capability::execute`
//! operations for provider-safe context inspection, compaction, clearing, action
//! audit lookup, and server-owned policy refs that future context summarizers
//! must preserve or omit.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Session-scoped read/write grant and selector checks |
//! | `contract` | Worker id, stream topic, scopes, schemas, and function contracts |
//! | `projection` | Provider-safe response shaping and timeline refs |
//! | `records` | Provider-safe record payloads, refs, ids, and proofs |
//! | `resource_store` | Resource creation, inspection, scope, and lifecycle events |
//! | `service` | Snapshot, compact, clear, action audit, and policy-ref behavior |
//! | `snapshot` | Session composition snapshot builder and bounded ref counters |
//! | `tests` | Redaction, replay, epoch, selector, and provider-safety tests |
//! | `validation` | Bounded input, idempotency, and error mapping helpers |
//!
//! # INVARIANT: context control never exposes raw prompt bodies
//!
//! Snapshot, action, survivor, exclusion, and policy-snapshot projections
//! contain bounded labels, counts, token estimates, typed non-wildcard refs,
//! redaction proof, and truncation proof only. They exclude raw system/soul
//! prompt bodies, hidden chain-of-thought, secrets, local paths, commands, logs,
//! grant ids, authority ids, and raw file contents. Policy snapshots fail closed
//! if the active survivor/exclusion set cannot fit in the bounded provider-safe
//! projection. Clear and compact mutate only the session event stream through
//! existing `context.cleared` and `compact.boundary` reducers; prior history
//! remains durable and inspectable but is excluded from future provider context
//! after those boundaries. Manual boundaries carry their internal invocation
//! correlation so reconstruction also excludes the matching post-boundary
//! capability result instead of producing an orphaned provider function output.
//! The compaction adapter seam is the summarizer strategy only. Context-control
//! snapshot/action/epoch and survivor/exclusion policy records, provider-safe
//! projections, replay refs, and audit custody stay server-owned; a future
//! summarizer replacement must carry rollback/disable metadata and prove it
//! consumed the current policy snapshot before binding policy may later consider
//! routing.

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::domains::session::event_store::EventStore;

mod authority;
pub(crate) mod contract;
mod projection;
mod records;
mod resource_store;
pub(crate) mod service;
mod snapshot;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) event_store: Arc<EventStore>,
    pub(crate) session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: Arc::clone(&deps.event_store),
            session_manager: Arc::clone(&deps.session_manager),
        }
    }
}

pub(crate) use crate::engine::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_ACTION_SCHEMA_ID, CONTEXT_CONTROL_EPOCH_KIND,
    CONTEXT_CONTROL_EPOCH_SCHEMA_ID, CONTEXT_CONTROL_SNAPSHOT_KIND,
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID, CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID,
    CONTEXT_POLICY_SNAPSHOT_KIND, CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND,
    CONTEXT_SURVIVOR_SCHEMA_ID,
};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let specs = contract::capabilities()?;
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::CONTEXT_CONTROL_TOPIC],
        service::function_registrations(specs, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
