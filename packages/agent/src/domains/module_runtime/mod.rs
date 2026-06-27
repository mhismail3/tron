//! Supervised module runtime envelopes.
//!
//! Module runtime owns durable `module_runtime_state` resources for Slice 23F's
//! first generic execution supervisor gate. Requests are accepted only after
//! `module_lifecycle::service::ensure_runtime_allowed` proves the referenced
//! lifecycle state is enabled in the current scope. The runtime record stores a
//! bounded metadata envelope with sandbox, network, secrets, timeout,
//! cancellation, shutdown, output-artifact refs, scoped-authority proof, and
//! provider-safe projections; feature semantics remain package-owned.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Runtime/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe runtime projections |
//! | `records` | Runtime envelope, idempotency, refs, and proof builders |
//! | `resource_store` | Resource inspection, stream events, and kind/schema helpers |
//! | `service` | Timestamp-injected request/list/inspect/cancel behavior |
//! | `validation` | Text, ref, timeout, lifecycle, and unsafe-payload checks |
//! | `tests` | Schema, authority, lifecycle, replay, cancel, and redaction regressions |
//!
//! # INVARIANT: runtime supervision is a metadata gate
//!
//! This domain does not install packages, restore dependencies, launch
//! interpreters, open PTYs/browsers, access networks, expose raw commands or
//! logs, or touch repo-managed `packages/agent/skills`. Runtime requests record
//! a supervised envelope and bounded refs only; disabled, quarantined,
//! rolled-back, pending, and missing lifecycle states fail closed before any
//! runtime state can be created.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod projection;
mod records;
mod resource_store;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{MODULE_RUNTIME_STATE_KIND, MODULE_RUNTIME_STATE_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MODULE_RUNTIME_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
