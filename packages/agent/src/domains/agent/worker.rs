//! Agent worker construction.

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

use super::Deps;
use super::contract;
use super::handlers;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "agent",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}
