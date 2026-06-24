//! Catalog discovery domain.
//!
//! This worker turns the live catalog and resource substrate into an
//! inspectable, durable self-discovery surface. It does not route or execute
//! discovered capabilities. Search and inspect are pure reads; conformance
//! report generation writes only a `catalog_discovery_report` resource plus a
//! catalog-discovery stream event.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Search, inspect, and report capability contracts |
//! | `errors` | Domain-local error helpers |
//! | `handlers` | Operation binding table |
//! | `params` | Request parsing, actor context, and visibility helpers |
//! | `projection` | Catalog summaries, filters, schema hints, and resource evidence |
//! | `report` | Conformance report checks and stream publication |
//! | `service` | Public search, inspect, and report orchestration |
//!
//! # INVARIANT: discovery is not invocation
//!
//! This domain may read catalog definitions, resource metadata, and stream
//! cursors, and may write its own report resources. It must never invoke a
//! discovered target function as part of search, inspect, or conformance.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod contract;
mod errors;
mod handlers;
mod params;
mod projection;
mod report;
pub(crate) mod service;

pub(crate) const WORKER: &str = "catalog_discovery";
pub(crate) const CATALOG_DISCOVERY_TOPIC: &str = "catalog.discovery";
pub(crate) const READ_SCOPE: &str = "catalog_discovery.read";
pub(crate) const WRITE_SCOPE: &str = "catalog_discovery.write";

pub(crate) const SEARCH_FUNCTION: &str = "catalog_discovery::search";
pub(crate) const INSPECT_FUNCTION: &str = "catalog_discovery::inspect";
pub(crate) const CONFORMANCE_REPORT_FUNCTION: &str = "catalog_discovery::conformance_report";

/// Catalog discovery dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
    }
}

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[CATALOG_DISCOVERY_TOPIC],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
