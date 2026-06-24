//! Durable goals and user-question lifecycle domain.
//!
//! Slice 7A owns the backend records that let agents and users inspect current
//! work and blocking questions from server truth. It records goals, questions,
//! answers, queue receipts, resource refs, stream evidence, trace refs, replay
//! refs, authority context, and revisions over the existing engine substrate.
//! It does not run an autonomous planner, schedule background work, notify
//! devices, launch subagents, expose a public `/engine` goal API, or add native
//! iOS Work/question panels.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Goal/question function contracts and schemas |
//! | `handlers` | Operation-key binding table |
//! | `service` | Resource-backed lifecycle behavior |
//! | `support` | Payload, scope, summary, stream, queue, and resource helpers |
//! | `types` | Serializable goal/question/answer records |
//!
//! # INVARIANT: Slice 7A records state, it does not execute work
//!
//! Goal creation may write a durable queue receipt that targets an explicitly
//! scoped `goals::*` function for inspectable handoff evidence. No queue item
//! is drained by this domain, and no hidden prompt queue, planner, scheduler,
//! notification path, subagent, or UI-specific answer channel is introduced.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
pub(crate) mod service;
mod support;
mod types;

pub(crate) const WORKER: &str = "goals";
pub(crate) const GOALS_LIFECYCLE_TOPIC: &str = "goals.lifecycle";
pub(crate) const READ_SCOPE: &str = "goals.read";
pub(crate) const WRITE_SCOPE: &str = "goals.write";

pub(crate) const GOAL_CREATE_FUNCTION: &str = "goals::create";
pub(crate) const GOAL_LIST_FUNCTION: &str = "goals::list";
pub(crate) const GOAL_INSPECT_FUNCTION: &str = "goals::inspect";
pub(crate) const GOAL_CANCEL_FUNCTION: &str = "goals::cancel";
pub(crate) const QUESTION_CREATE_FUNCTION: &str = "goals::question_create";
pub(crate) const QUESTION_LIST_FUNCTION: &str = "goals::question_list";
pub(crate) const QUESTION_INSPECT_FUNCTION: &str = "goals::question_inspect";
pub(crate) const QUESTION_ANSWER_FUNCTION: &str = "goals::question_answer";

pub(crate) const GOAL_KIND: &str = "goal";
pub(crate) const GOAL_SCHEMA_ID: &str = "tron.resource.goal.v1";
pub(crate) const USER_QUESTION_KIND: &str = "user_question";
pub(crate) const USER_QUESTION_SCHEMA_ID: &str = "tron.resource.user_question.v1";
pub(crate) const GOAL_ANSWER_KIND: &str = "goal_answer";
pub(crate) const GOAL_ANSWER_SCHEMA_ID: &str = "tron.resource.goal_answer.v1";

const STREAM_TOPICS: &[&str] = &[GOALS_LIFECYCLE_TOPIC];

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
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
