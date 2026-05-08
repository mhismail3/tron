//! Agent worker construction.

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::domains::worker::DomainWorkerModule;

use super::Deps;
use super::contract;
use super::handlers;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::server::domains::worker::domain_worker_module(
        "agent",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}
