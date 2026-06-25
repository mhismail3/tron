//! Durable system update diagnostics resource foundation.
//!
//! Slice 14C adds backend custody for signed-release/update diagnostic facts
//! before any native iOS update panel, live update check, installer, restart,
//! package/catalog registration, or deploy automation work. This domain owns
//! `update_diagnostic_record` resources, bounded release/provenance metadata,
//! source/evidence/signature refs, retention fields, trace/replay refs,
//! redacted list/inspect projections, fingerprinted idempotency evidence, and
//! lifecycle events. Provider-visible projections stay byte-bounded while
//! preserving UTF-8 character boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Update diagnostics/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe update diagnostic projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Ref, retention, release metadata, idempotency, and text bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: update diagnostics stores metadata refs, not updater material
//!
//! Update-diagnostics truth lives in current-session or current-workspace engine
//! resources whose payloads carry bounded signed-release/provenance metadata
//! only. These operations do not accept raw update payloads, package bytes,
//! production endpoint details, installer/restart/deploy commands, filesystem
//! paths, or secret-like caller material. Diagnostic timestamps are supplied by
//! `capability::execute` or tests; this domain does not sample wall-clock time
//! directly.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod projection;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{UPDATE_DIAGNOSTIC_RECORD_KIND, UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::UPDATE_DIAGNOSTICS_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
