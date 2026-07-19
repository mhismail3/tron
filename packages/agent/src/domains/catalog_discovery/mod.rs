//! Catalog discovery domain.
//!
//! This worker turns the live catalog and resource substrate into an
//! inspectable, durable self-discovery surface. It does not route or execute
//! discovered capabilities. Search and inspect are pure reads; conformance
//! report generation writes only a `catalog_discovery_report` resource plus a
//! catalog-discovery stream event. Report replay is owned by the engine ledger:
//! the bounded invocation-envelope idempotency key determines both the ledger
//! identity and a hashed, scope-bound report resource id, while the raw key is
//! never duplicated in request payloads, stored in report resources, or
//! returned in projections.
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
//! Handler registrations retain the engine host directly; discovery services
//! borrow it and own no parallel dependency container.

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

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[CATALOG_DISCOVERY_TOPIC],
        handlers::function_registrations(contract::capabilities()?, deps.engine_host.clone())?,
    )
}

#[cfg(test)]
mod tests;
