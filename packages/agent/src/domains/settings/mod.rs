//! settings domain worker.
//!
//! This module owns canonical function execution for the settings namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them. Settings
//! updates persist the sparse profile overlay, then reload the profile runtime so
//! subsequent turns use the new provider and loop settings.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod profile;
pub(crate) use deps::Deps;
pub(crate) use profile::operations::{settings_reset_to_defaults_value, settings_update_value};
pub use profile::*;

use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::registration::worker::domain_worker_module(
            "settings",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}
