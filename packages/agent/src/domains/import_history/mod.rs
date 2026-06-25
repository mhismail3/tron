//! Durable import/session-resource graph lineage foundation.
//!
//! Slice 14B adds backend custody for narrow import-history and generic
//! session/resource graph lineage records before any native iOS import tree,
//! workspace graph, repository visualization, or update diagnostics work.
//! This domain owns `import_history_record` resources, bounded lineage
//! metadata, parent/child/source refs, retention fields, trace/replay refs,
//! redacted list/inspect projections, fingerprinted idempotency evidence, and
//! lifecycle events. Provider-visible projections stay byte-bounded while
//! preserving UTF-8 character boundaries. The stored shape is intentionally
//! generic-graph-first:
//! render hints stay generic, raw repository trees and import payloads are not
//! accepted, and native tree/session UI remains a later proof-driven slice.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Import-history/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe graph projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Ref, retention, subject, idempotency, and text bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: import history stores lineage refs, not raw imports
//!
//! Import-history truth lives in current-session or current-workspace engine
//! resources whose payloads carry bounded lineage refs and metadata only.
//! These operations do not accept raw repository contents, raw import payloads,
//! unbounded trees, filesystem paths, or secret-like caller material. Import
//! timestamps are supplied by `capability::execute` or tests; this domain does
//! not sample wall-clock time directly.

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

pub(crate) use crate::engine::{IMPORT_HISTORY_RECORD_KIND, IMPORT_HISTORY_RECORD_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::IMPORT_HISTORY_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
