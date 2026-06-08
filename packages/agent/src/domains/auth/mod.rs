//! auth domain worker.
//!
//! This module owns canonical function execution for the auth namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Credential reads/writes and account selection live under `credentials/`.
//! OAuth flow state and completion live under `oauth/`. This root only
//! registers the auth worker and exposes the concrete ownership modules.

pub(crate) mod contract;
pub mod credentials;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod oauth;
pub(crate) mod stream;
pub(crate) use deps::Deps;

use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::registration::worker::domain_worker_module(
            "auth",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}
