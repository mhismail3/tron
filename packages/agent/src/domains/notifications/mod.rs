//! Server-owned notification policy, inbox state, and delivery evidence.
//!
//! This domain decides whether a notification may be delivered, records the
//! durable notification and delivery outcome, and delegates eligible push
//! delivery to [`crate::platform::apns`]. It never owns raw device tokens or
//! provider credentials.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Explicit notification/device grant and selector checks |
//! | `contract` | Worker id, stream topic, and authority scope constants |
//! | `delivery` | Policy-aware APNs dispatch and durable delivery evidence |
//! | `projection` | Bounded redacted inbox and delivery projections |
//! | `service` | Timestamp-injected send/list/inspect/mark-read/mark-all-read behavior |
//! | `validation` | Request parsing, event-family, text, and retention bounds |
//! | `tests` | Module-local inbox, badge, delivery evidence, authority, scope, and fixture regressions |
//!
//! # INVARIANT: no fake local inbox
//!
//! Notification truth lives in engine resources scoped to the current trusted
//! session or workspace. Push is an optional delivery effect, not a second
//! source of notification state. Permission prompts and token registration are
//! owned by the iOS lifecycle; private token custody and relay credentials are
//! owned by the APNs platform adapter. This domain creates no client-local
//! inbox, hidden worker, background loop, or public route. Notification and
//! delivery timestamps are supplied by `capability::execute` or explicit test
//! seams; this domain does not sample wall-clock time directly.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod delivery;
mod projection;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) apns_runtime: crate::platform::apns::ApnsRuntime,
}

pub(crate) use crate::engine::{
    NOTIFICATION_DELIVERY_KIND, NOTIFICATION_DELIVERY_SCHEMA_ID, NOTIFICATION_KIND,
    NOTIFICATION_SCHEMA_ID,
};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::NOTIFICATION_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
