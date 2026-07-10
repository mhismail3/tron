//! Server-owned device registration foundation.
//!
//! Slice 13 restores the backend device schema and redacted read substrate
//! without restoring iOS APNs entitlements, permission prompts, registration,
//! or a live APNs transport. Production code lists and inspects existing
//! `device_registration` resources. Test-only fixtures exercise the deferred
//! registration schema's hash-only APNs token custody, environment policy,
//! opt-in preferences, and lifecycle evidence. The paired-device request broker in
//! `platform::device_broker` remains a local request/response substrate; it
//! does not own APNs token custody or notification delivery policy.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Worker id, stream topic, and authority scope constants |
//! | `projection` | Bounded redacted device list/inspect projections |
//! | `service` | Production list/inspect behavior plus test-only registration fixtures for the deferred trusted transport |
//! | `support` | Record construction, authority guards, refs, and redaction helpers |
//! | `validation` | Payload parsing, APNs environment/token, and bounds checks |
//! | `tests` | Token redaction, authority, environment, and scope regressions |
//!
//! # INVARIANT: device tokens are never provider-visible
//!
//! The production engine does not accept APNs token material while live APNs
//! transport is deferred. Test-only registration fixtures prove that the
//! registered resource schema retains only full SHA-256 hash custody evidence;
//! projections and lifecycle events never return raw tokens, raw-token
//! prefixes/suffixes/previews, or full token hashes. Push remains opt-in and
//! live APNs transport is disabled by default in this foundation. A future
//! trusted transport must own registration and unregistration explicitly; they
//! are not model-facing `capability::execute` operations.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod projection;
pub(crate) mod service;
mod support;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(contract::WORKER, &[], Vec::new())
}

#[cfg(test)]
mod tests;
