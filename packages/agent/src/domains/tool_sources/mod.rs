//! Read-only tool-source evidence projection domain.
//!
//! This domain is the read-only projection boundary over existing
//! `tool_source_proposal` and `tool_source_conformance_report` resources. It
//! intentionally owns no proposal or report writer; tests seed compatible
//! records through the engine resource store. Agent-visible access is limited to
//! `capability::execute` operation values `tool_source_list` and
//! `tool_source_inspect`; inspect revalidates stored resource kind/schema
//! before projecting payloads.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `service` | Read-only list/inspect authorization and projection |
//! | `validation` | Bounded list/inspect request readers and errors |
//! | `tests` | Read authority, scoping, schema, projection, and non-goal guards |
//!
//! # INVARIANT: stored tool-source evidence remains inert
//!
//! This domain must never install packages, start MCP servers, register catalog
//! tools, execute declared tools, crawl/login/search the web, or decide trust.
//! The read path treats stored proposal and report fields as inert data, bounds
//! list cardinality and inspected schema previews, and never acts on record
//! contents.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod service;
mod validation;

pub(crate) const WORKER: &str = "tool_sources";
pub(crate) const TOOL_SOURCE_TOPIC: &str = "tool_sources.lifecycle";
pub(crate) const READ_SCOPE: &str = "tool_sources.read";
pub(crate) const SCHEMA_VERSION: &str = "tron.tool_source.v1";

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[TOOL_SOURCE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
