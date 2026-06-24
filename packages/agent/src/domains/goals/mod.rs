//! Goal and user-question lifecycle foundation.
//!
//! This Slice 7A domain owns durable backend records for user goals, user
//! questions, and answer provenance. It deliberately does not run goals,
//! schedule work, create notification inboxes, launch subagents, or add native
//! iOS question/work surfaces.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `errors` | Domain-local error helpers |
//! | `schema_tests` | Resource/schema drift guards |
//! | `service` | Durable goal/question lifecycle behavior |
//! | `support` | Scope, validation, resource refs, and stream helpers |
//! | `types` | Serializable goal, question, and answer records |
//!
//! # INVARIANT: lifecycle records only
//!
//! The engine provides resources, streams, traces, replay, and idempotency.
//! This domain owns the durable records that let users inspect pending work and
//! answer handoffs. Question answers acquire a short engine resource lease on
//! the question before recording answer resources so expected-version handoffs
//! remain serialized. Queue refs are evidence refs only in this slice; no
//! hidden prompt queue, autonomous runner, planner, scheduler, notification
//! path, or subagent dispatch is restored here.

mod errors;
pub(crate) mod service;
mod support;
mod types;

pub(crate) const WORKER: &str = "goals";
pub(crate) const GOALS_LIFECYCLE_TOPIC: &str = "goals.lifecycle";
pub(crate) const WRITE_SCOPE: &str = "goals.write";
pub(crate) const USER_QUESTION_KIND: &str = "user_question";
pub(crate) const USER_QUESTION_SCHEMA_ID: &str = "tron.resource.user_question.v1";
pub(crate) const GOAL_ANSWER_KIND: &str = "goal_answer";
pub(crate) const GOAL_ANSWER_SCHEMA_ID: &str = "tron.resource.goal_answer.v1";

#[cfg(test)]
mod schema_tests;
#[cfg(test)]
mod tests;
