//! External tool-source proposal provenance domain.
//!
//! Slice 9A restores only an inert proposal and preflight evidence boundary for
//! external tool sources. The runtime worker is read-only over existing
//! `tool_source_proposal` and `tool_source_conformance_report` resources; writer
//! helpers remain test fixtures for resource-shape, authority, and rejection
//! guards until a future accepted worker wires an explicit create contract.
//! Agent-visible access remains read-only through
//! `capability::execute` operation values `tool_source_list` and
//! `tool_source_inspect`; inspect revalidates stored resource kind/schema
//! before projecting payloads.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `service` | Read-only list/inspect projection plus test fixtures for proposal/report records |
//! | `validation` | Bounded payload readers and proposal/report rejection rules |
//! | `tests` | Authority, validation, idempotency, scoping, and non-goal guards |
//!
//! # INVARIANT: proposals are not activation
//!
//! This domain must never install packages, start MCP servers, register catalog
//! tools, execute declared tools, crawl/login/search the web, or decide trust.
//! Records preserve source identity, provenance, sandbox intent, schema/tool
//! metadata, expected worker/package linkage, trace/replay refs, lifecycle
//! state, and bounded evidence for later inspection. Retained proposal strings
//! may describe inert provenance or prohibitions, but not active, passive, or
//! nominal install/enable/register/launch/execute intent.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod service;
mod validation;

pub(crate) const WORKER: &str = "tool_sources";
pub(crate) const TOOL_SOURCE_TOPIC: &str = "tool_sources.lifecycle";
pub(crate) const READ_SCOPE: &str = "tool_sources.read";
#[cfg(test)]
pub(crate) const PROPOSE_SCOPE: &str = "tool_sources.propose";
pub(crate) const SCHEMA_VERSION: &str = "tron.tool_source.v1";

#[cfg(test)]
pub(crate) const PROPOSE_FUNCTION: &str = "tool_sources::propose";
#[cfg(test)]
pub(crate) const REPORT_FUNCTION: &str = "tool_sources::conformance_report";

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
