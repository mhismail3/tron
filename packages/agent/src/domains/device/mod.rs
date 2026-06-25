//! Server-owned device registration foundation.
//!
//! Slice 13 restores the backend device substrate without restoring iOS APNs
//! entitlements, permission prompts, or a live APNs transport. This domain owns
//! durable `device_registration` resources, hash-only APNs token custody
//! evidence, explicit APNs environment policy, opt-in notification preferences,
//! and lifecycle stream evidence. The paired-device request broker in
//! `platform::device_broker` remains a local request/response substrate; it
//! does not own APNs token custody or notification delivery policy.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Worker id, stream topic, and authority scope constants |
//! | `projection` | Bounded redacted device list/inspect projections |
//! | `service` | Timestamp-injected register, unregister, list, and inspect behavior |
//! | `support` | Record construction, authority guards, refs, and redaction helpers |
//! | `validation` | Payload parsing, APNs environment/token, and bounds checks |
//! | `tests` | Token redaction, authority, environment, and scope regressions |
//!
//! # INVARIANT: device tokens are never provider-visible
//!
//! Device registration accepts APNs token material only in trusted system/admin
//! calls. Stored resources retain only full SHA-256 hash custody evidence;
//! projections and lifecycle events never return raw tokens, raw-token
//! prefixes/suffixes/previews, or full token hashes. Push remains opt-in and
//! live APNs transport is disabled by default in this foundation. Register and
//! unregister timestamps are supplied by the `capability::execute` adapter or
//! explicit test seams; this domain does not sample wall-clock time directly.

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
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::DEVICE_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
