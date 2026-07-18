//! Native A2UI v0.9.1 feature domain.
//!
//! This domain owns deterministic server-driven native UI definitions without
//! placing product behavior in the universal engine. Definitions are canonical
//! A2UI message sequences pinned to the Tron sheet catalog; SwiftUI remains a
//! precompiled client implementation. Active definition revisions use a
//! dedicated compare-and-swap SQLite store, while session compaction sheets
//! retain resumable transient lifecycle state.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `builtins` | Shared known-good settings, compaction, and lab definitions |
//! | `catalog` | Component, modifier, native-function, and safety limits |
//! | `contract` | Canonical capabilities and `native_ui.surface` topic |
//! | `model` | Definition, revision, catalog, and snapshot DTOs |
//! | `providers` | Settings and durable compaction-event data projections |
//! | `service` | Validation, publication, reconstruction, streaming, and actions |
//! | `store` | Domain-owned SQLite revisions and transient lifecycle |
//! | `validation` | Fail-closed A2UI graph/catalog/capability validation |
//!
//! # Invariants
//!
//! Native UI never evaluates downloaded Swift, JavaScript, shell text, or raw
//! engine requests. A definition can compose only cataloged precompiled views,
//! ordered typed modifiers, advertised client functions, and live engine
//! capability bindings. Invalid definitions and stream batches never replace
//! last-known-good state. Pairing and repair remain outside this domain in the
//! always-native settings shell.

mod builtins;
mod catalog;
pub(crate) mod contract;
mod deps;
mod handlers;
mod model;
mod providers;
mod service;
mod store;
mod validation;

pub(crate) use deps::Deps;

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps)?;
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}
