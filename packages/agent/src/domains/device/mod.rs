//! Server-owned private device registration.
//!
//! Trusted engine clients register iOS APNs tokens through the internal
//! `device::register` transport function. Durable `device_registration`
//! resources retain policy and a token hash; raw tokens live only in the
//! private [`crate::platform::apns`] store. Registration is authenticated
//! transport infrastructure and is never model-visible.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Internal registration contracts, stream topic, and authority scopes |
//! | `handlers` | Trusted transport bindings for registration and unregistration |
//! | `service` | Registration lifecycle behavior |
//! | `support` | Record construction, transport guards, refs, and redaction helpers |
//! | `validation` | Payload parsing, APNs environment/token, and bounds checks |
//! | `tests` | Token redaction, authority, environment, and scope regressions |
//!
//! # INVARIANT: device tokens are never provider-visible
//!
//! Raw tokens may cross only the trusted engine-client registration boundary
//! and the private token store. Resources, lifecycle events,
//! traces, and logs never return raw tokens, token fragments, or full token
//! hashes. Registration and unregistration are transport-only and never enter
//! the model-facing direct-tool set. The fixed kernel stores no notification
//! inbox and performs no APNs delivery; higher-level delivery belongs in a
//! persistent worker.
//! Registration identity includes the app bundle and APNs environment so
//! side-by-side app variants cannot overwrite one another. Registering a token
//! route durably retires older resources for the same bundle and environment,
//! preventing duplicate relay delivery while preserving lifecycle history.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
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
