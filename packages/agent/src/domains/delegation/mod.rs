//! Minimal real child-agent delegation workflow.
//!
//! Delegation is a narrow Level 2 layer over session creation, `agent::prompt`,
//! engine resources, causal invocations, and lifecycle streams. It deliberately
//! does not introduce a generic task/workflow engine. A delegation owns only a
//! bounded handoff, a fresh non-fork child session, an exact child run, and an
//! explicitly joined result.
//!
//! ## Invariants
//!
//! - Child sessions are created fresh; session fork lineage is never used.
//! - The durable delegation record and deterministic child identity are
//!   prepared before child execution starts.
//! - Child capability execution is server-marked read-only and cannot be
//!   widened by provider payloads.
//! - At most three nonterminal delegations may exist in one parent session.
//! - Results never enter parent context until `accept_result` wins an exact
//!   version compare-and-set.
//! - Restart repair requires exact-run durable completion evidence; an
//!   assistant message or intermediate turn boundary alone is insufficient.
//! - Every durable lifecycle change emits `delegation.changed` as a
//!   session-scoped invalidation signal.
//! - Legacy `subagent_task.v1` records are not delegation records.

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::{
    core::Orchestrator, session_manager::SessionManager,
};
use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::domains::session::event_store::EventStore;

pub(crate) mod contract;
pub(crate) mod projection;
pub(crate) mod service;

#[derive(Clone)]
pub(crate) struct Deps {
    engine_host: crate::engine::EngineHostHandle,
    event_store: Arc<EventStore>,
    orchestrator: Arc<Orchestrator>,
    session_manager: Arc<SessionManager>,
    start_admission: Arc<tokio::sync::Mutex<()>>,
}

impl Deps {
    pub(crate) fn from_components(
        engine_host: crate::engine::EngineHostHandle,
        event_store: Arc<EventStore>,
        orchestrator: Arc<Orchestrator>,
        session_manager: Arc<SessionManager>,
    ) -> Self {
        Self {
            engine_host,
            event_store,
            orchestrator,
            session_manager,
            start_admission: Arc::new(tokio::sync::Mutex::new(())),
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let deps = Deps::from_components(
        deps.engine_host.clone(),
        Arc::clone(&deps.event_store),
        Arc::clone(&deps.orchestrator),
        Arc::clone(&deps.session_manager),
    );
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::TOPIC],
        service::function_registrations(contract::capabilities()?, deps)?,
    )
}

#[cfg(test)]
mod tests;
