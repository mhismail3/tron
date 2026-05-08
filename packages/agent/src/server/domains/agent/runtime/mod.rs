//! Agent prompt runtime support owned by canonical engine functions.
//!
//! The production prompt path is owned by `agent::prompt` and hidden apply/run
//! functions. Client protocols reach it only through `/engine` `invoke`; this module owns
//! the reusable prompt bootstrap, run spawning, queue drain, completion
//! helpers, cleanup guards, and small runtime predicates used by canonical
//! agent functions and tests. The runtime is split into two domain-owned
//! verticals: `service/` owns run orchestration and queue handoff, while
//! `runtime/` owns event payload construction, prompt bootstrap, pending-result
//! injection, skill-context construction, and session-update reads.

mod cleanup;
mod predicates;
pub(crate) mod runtime;
pub(crate) mod service;
