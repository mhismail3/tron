//! Durable repository tree snapshot resource foundation.
//!
//! Slice 14D adds backend custody for content-free repository tree snapshots
//! before any native repository visualization, import preview, or git mutation
//! work. This domain owns `repository_tree_snapshot` resources, repository/root
//! refs, tree object refs, bounded normalized relative path metadata, aggregate
//! counts, source/evidence refs, retention fields, trace/replay refs, redacted
//! list/inspect projections, fingerprinted idempotency evidence, and lifecycle
//! events. Provider-visible projections stay byte-bounded while preserving
//! UTF-8 character boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Repository-tree/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe snapshot projections |
//! | `service` | Timestamp-injected snapshot/list/inspect behavior |
//! | `validation` | Ref, path, count, retention, idempotency, and text bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: repository tree stores metadata, not contents
//!
//! Snapshot truth lives in current-session or current-workspace engine resources
//! whose payloads carry bounded content-free metadata only. These operations do
//! not accept raw repository contents, raw import payloads, unbounded trees,
//! absolute paths, unsafe relative paths, blob bytes, or secret-like caller
//! material. Snapshot timestamps are supplied by `capability::execute` or tests;
//! this domain does not sample wall-clock time directly.

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

pub(crate) use crate::engine::{REPOSITORY_TREE_SNAPSHOT_KIND, REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::REPOSITORY_TREE_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
