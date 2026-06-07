//! session domain worker.
//!
//! This module owns canonical function execution for the session namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Lifecycle, history, reconstruction, archive/delete, and export operation
//! bodies live in `operations/`; command/query/reconstruct services remain
//! nearby and take the narrowed `SessionDeps` bundle. `commands/` is split by
//! lifecycle action. The prompt context is owned by the agent runtime and
//! primitive state; this domain does not preload external policy planes.
//! `session::list` is the server-owned dashboard query for clients and supports
//! domain-local filtering and pagination through the session event store. Its
//! user-visible filter intentionally hides abandoned chat drafts that contain
//! only the root `session.start` event, while preserving direct reconstruction
//! and export by session ID.

pub(crate) mod contract;
pub(crate) mod deps;
pub mod event_store;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "session",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) mod commands;
pub(crate) mod queries;
pub(crate) mod reconstruct;
