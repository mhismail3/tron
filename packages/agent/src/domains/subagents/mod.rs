//! Subagent task lifecycle foundation.
//!
//! Slice 10A restores only inert delegation task records. Trusted internal
//! callers can create and update `subagent_task` resources as bounded lifecycle
//! evidence, while model-visible access remains read-only through
//! `capability::execute` operation values `subagent_task_list` and
//! `subagent_task_inspect`. List/inspect revalidate stored resource
//! kind/schema before returning allowlisted, bounded, redacted projections.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `projection` | Allowlisted, bounded, redacted read projections for list/inspect |
//! | `service` | Internal lifecycle writes plus read-only list/inspect projection |
//! | `validation` | Bounded payload readers and redaction/non-goal guards |
//! | `tests` | Authority, scoping, idempotency, schema, and non-goal guards |
//!
//! # INVARIANT: lifecycle records are not delegation execution
//!
//! This domain must never start workers, processes, jobs, MCP servers, tool
//! execution, browser/search/network work, trust promotion, or result merging.
//! It records only task identity, parent session/trace/workspace scope,
//! objective/prompt summaries, lifecycle state, bounded refs, and optional
//! result/error placeholders for later inspection.

#![allow(dead_code)]

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod projection;
pub(crate) mod service;
mod validation;

pub(crate) const WORKER: &str = "subagents";
pub(crate) const SUBAGENT_TASK_TOPIC: &str = "subagents.lifecycle";
pub(crate) const READ_SCOPE: &str = "subagents.read";
pub(crate) const WRITE_SCOPE: &str = "subagents.write";
pub(crate) const SCHEMA_VERSION: &str = "tron.subagent_task.v1";

pub(crate) const CREATE_TASK_FUNCTION: &str = "subagents::create_task";
pub(crate) const UPDATE_TASK_FUNCTION: &str = "subagents::update_task";

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
    }
}

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[SUBAGENT_TASK_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
