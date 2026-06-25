//! Durable import preview resource foundation.
//!
//! Slice 14E adds backend custody for content-free import preview records before
//! any import execution, repository visualization, native tree UI, or git
//! mutation work. This domain owns `import_preview` resources that link
//! import-history/resource-graph refs with repository-tree snapshot refs,
//! bounded normalized relative path metadata, preview summaries, aggregate
//! counts, source/evidence refs, retention fields, trace/replay refs, redacted
//! list/inspect projections, fingerprinted idempotency evidence, and lifecycle
//! events. Provider-visible projections stay byte-bounded while preserving UTF-8
//! character boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Import-preview/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe preview projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Ref, path, summary, count, retention, idempotency, and text bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: import preview stores refs and metadata, not import contents
//!
//! Preview truth lives in current-session or current-workspace engine resources
//! whose payloads carry bounded content-free metadata and refs only. These
//! operations do not accept raw import payloads, raw preview payloads, raw
//! repository contents, raw file contents, unbounded trees, absolute paths,
//! unsafe relative paths, blob bytes, git mutation instructions, or secret-like
//! caller material. Preview timestamps are supplied by `capability::execute` or
//! tests; this domain does not sample wall-clock time directly.

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

pub(crate) use crate::engine::{IMPORT_PREVIEW_KIND, IMPORT_PREVIEW_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::IMPORT_PREVIEW_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
