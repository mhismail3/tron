//! Subagent task lifecycle and worker-launch foundation.
//!
//! Slice 10A restored inert delegation task records. Slice 10B keeps
//! `subagent_task` as the durable parent causality anchor and adds a controlled
//! launch/status/result/cancel lifecycle over the same resource. The launch path
//! records a bounded placeholder worker/job policy, parent refs, concurrency
//! decision, cancellation path, and replay/evidence refs, but it still does not
//! start a child process, external worker, package, tool, browser, network
//! action, scheduler, or result merge.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `execution` | Controlled launch/status/result/cancel lifecycle over `subagent_task` |
//! | `projection` | Allowlisted, bounded, redacted read projections for list/inspect |
//! | `service` | Internal lifecycle writes plus read-only list/inspect projection |
//! | `validation` | Bounded payload readers and redaction/non-goal guards |
//! | `tests` | Authority, scoping, idempotency, schema, and non-goal guards |
//!
//! # INVARIANT: launch records are not child execution
//!
//! This domain must never start OS processes, external workers, package
//! launchers, MCP servers, tool execution, browser/search/network work, trust
//! promotion, autonomous scheduling, or result merging. Launch means "record a
//! scoped subagent worker lifecycle resource under explicit placeholder policy",
//! not "spawn an agent".

#![allow(dead_code)]

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod execution;
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
mod execution_tests;
#[cfg(test)]
mod tests;
