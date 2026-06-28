//! Durable program execution resource foundation.
//!
//! Slice 15A adds backend custody for content-free program execution records
//! before any embedded runtime, subprocess, package manager, notebook, PTY, file
//! write, result merge, or native UI work. This domain owns `program_execution`
//! resources that store deterministic runtime/language identifiers, I/O-envelope
//! metadata, resource-limit policy, source/input/output refs or fingerprints,
//! retention fields, trace/replay refs, redacted list/inspect projections,
//! fingerprinted idempotency evidence, and lifecycle events. Provider-visible
//! projections stay byte-bounded while preserving UTF-8 character boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Program-execution/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe program projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Runtime metadata, ref, resource-limit, I/O-envelope, retention, idempotency, and text bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: program execution stores metadata, not executable contents
//!
//! Program truth lives in current-session or current-workspace engine resources
//! whose payloads carry bounded content-free metadata and refs only. These
//! operations do not accept raw code bodies, command strings, shell snippets,
//! raw stdin/stdout/stderr, runtime install directives, absolute paths, unsafe
//! paths, blob bytes, process handles, network behavior, file-write requests, or
//! secret-like caller material. Program timestamps are supplied by
//! `capability::execute` or tests; this domain does not sample wall-clock time
//! directly. Module-owned job execution records may link to delegated runtime
//! and output resource refs, but the record remains metadata evidence only and
//! must not be loosened to carry the command, stdio, process ids, install
//! steps, paths, network requests, or raw output previews.

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

pub(crate) use crate::engine::{PROGRAM_EXECUTION_KIND, PROGRAM_EXECUTION_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::PROGRAM_EXECUTION_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
