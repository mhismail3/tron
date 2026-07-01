//! Context-control primitive for session context visibility and epoch changes.
//!
//! Context control owns durable `context_control_snapshot`,
//! `context_control_action`, and `context_control_epoch` resources. It exposes a
//! narrow first-party UI surface plus model-facing `capability::execute`
//! operations for provider-safe context inspection, compaction, clearing, and
//! action audit lookup.
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
//! | `service` | Snapshot, compact, clear, list, and inspect behavior |
//! | `snapshot` | Session composition snapshot builder and bounded ref counters |
//! | `tests` | Redaction, replay, epoch, selector, and provider-safety tests |
//! | `validation` | Bounded input, idempotency, and error mapping helpers |
//!
//! # INVARIANT: context control never exposes raw prompt bodies
//!
//! Snapshot and action projections contain bounded labels, counts, token
//! estimates, refs, redaction proof, and truncation proof only. They exclude raw
//! system/soul prompt bodies, hidden chain-of-thought, secrets, local paths,
//! commands, logs, grant ids, authority ids, and raw file contents. Clear and
//! compact mutate only the session event stream through existing
//! `context.cleared` and `compact.boundary` reducers; prior history remains
//! durable and inspectable but is excluded from future provider context after
//! those boundaries.

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
    CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID,
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
