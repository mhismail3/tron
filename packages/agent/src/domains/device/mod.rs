//! Server-owned device registration and redacted inspection.
//!
//! Trusted engine clients register iOS APNs tokens through the internal
//! `device::register` transport function. Durable `device_registration`
//! resources retain policy and a token hash; raw tokens live only in the
//! private [`crate::platform::apns`] store. Models can list and inspect the
//! redacted registration records, but cannot register or unregister devices.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Internal registration contracts, stream topic, and authority scopes |
//! | `handlers` | Trusted transport bindings for registration and unregistration |
//! | `projection` | Bounded redacted device list/inspect projections |
//! | `service` | Registration lifecycle plus list/inspect behavior |
//! | `support` | Record construction, authority guards, refs, and redaction helpers |
//! | `validation` | Payload parsing, APNs environment/token, and bounds checks |
//! | `tests` | Token redaction, authority, environment, and scope regressions |
//!
//! # INVARIANT: device tokens are never provider-visible
//!
//! Raw tokens may cross only the trusted engine-client registration boundary
//! and the private APNs transport. Resources, projections, lifecycle events,
//! traces, and logs never return raw tokens, token fragments, or full token
//! hashes. Registration and unregistration are deliberately not model-facing
//! `capability::execute` operations. Device notification policy consumes the
//! canonical event-family taxonomy owned by the notifications domain so the
//! default send family is always eligible under the default device policy.
//! Registration identity includes the app bundle and APNs environment so
//! side-by-side app variants cannot overwrite one another. Registering a token
//! route durably retires older resources for the same bundle and environment,
//! preventing duplicate relay delivery while preserving lifecycle history.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
mod projection;
pub(crate) mod service;
mod support;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) apns_runtime: crate::platform::apns::ApnsRuntime,
}

pub(crate) use crate::engine::{DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps {
        engine_host: deps.engine_host.clone(),
        apns_runtime: deps.apns_runtime.clone(),
    };
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

#[cfg(test)]
mod tests;
