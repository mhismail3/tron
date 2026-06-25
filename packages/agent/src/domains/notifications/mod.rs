//! Server-owned notification inbox and delivery evidence foundation.
//!
//! Slice 13 restores durable notification resources before any native iOS inbox
//! or live APNs transport. This domain owns `notification` read state,
//! badge-count semantics, bounded list/inspect projections, and
//! `notification_delivery` evidence records for inbox-only, policy-skipped, or
//! APNs-disabled delivery paths. It does not send production APNs requests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Explicit notification/device grant and selector checks |
//! | `contract` | Worker id, stream topic, and authority scope constants |
//! | `delivery` | Timestamp-injected durable `notification_delivery` evidence creation and readback |
//! | `projection` | Bounded redacted inbox and delivery projections |
//! | `service` | Timestamp-injected send/list/inspect/mark-read/mark-all-read behavior |
//! | `validation` | Request parsing, event-family, text, and retention bounds |
//! | `tests` | Inbox, badge, delivery evidence, authority, and scope regressions |
//!
//! # INVARIANT: no fake local inbox
//!
//! Notification truth lives in engine resources scoped to the current trusted
//! session or workspace. iOS can later render this server truth, but this domain
//! does not create client-local-only state, APNs entitlements, permission
//! prompts, hidden workers, background loops, or public `/engine` routes.
//! Notification and delivery timestamps are supplied by `capability::execute` or
//! explicit test seams; this domain does not sample wall-clock time directly.

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
