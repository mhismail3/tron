//! Subagent task lifecycle and bounded delegated module work.
//!
//! Slice 24C keeps `subagent_task` as the durable parent causality anchor and
//! activates a single accepted delegation path: the jobs/program-execution
//! module pack. Launch records a bounded summary-only handoff, explicit worker
//! and module-pack selection, delegated module runtime/job/program refs, and a
//! reviewable result-merge proposal contract. Follow-ups inspect or cancel the
//! delegated module/job pair through the module runtime binding checks; they do
//! not silently mutate the parent conversation.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `execution` | Controlled launch/status/result/cancel lifecycle over delegated module refs |
//! | `projection` | Allowlisted, bounded, redacted read projections for list/inspect |
//! | `service` | Read-only list/inspect projection plus test fixtures for task records |
//! | `validation` | Bounded payload readers and redaction/non-goal guards |
//! | `tests` | Authority, scoping, idempotency, schema, and non-goal guards |
//!
//! # INVARIANT: delegated execution stays explicit and reviewable
//!
//! This domain must never start arbitrary workers, packages, MCP servers,
//! browser/search/network work, trust promotion, autonomous scheduling, or
//! result merging. The only activated path is the accepted
//! jobs/program-execution module pack selected by exact payload fields and exact
//! resource selectors. Completion is surfaced as merge-proposal evidence for
//! review, not as hidden parent-state mutation. Delegated launch and follow-up
//! grants must include exact module runtime, job, program-execution, lifecycle,
//! and subagent-task selectors without implicit `agent_state` authority. Launch replay
//! must recover the same delegated runtime/job/program refs from module
//! supervision metadata before creating the parent task, or fail closed.

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

#[cfg(test)]
pub(crate) const CREATE_TASK_FUNCTION: &str = "subagents::create_task";
#[cfg(test)]
pub(crate) const UPDATE_TASK_FUNCTION: &str = "subagents::update_task";

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
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
