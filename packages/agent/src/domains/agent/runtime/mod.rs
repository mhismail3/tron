//! Agent prompt runtime support owned by canonical engine functions.
//!
//! The production prompt path is owned by `agent::prompt` and hidden apply/run
//! functions. Client protocols reach it only through `/engine` `invoke`; this module owns
//! the reusable prompt bootstrap, run spawning, completion helpers and cleanup
//! guards. The runtime is split into two domain-owned
//! verticals: `service/` owns run orchestration, while
//! `runtime/` owns event payload construction, prompt bootstrap, pending-result
//! injection, and session-update reads.

mod cleanup;
pub(crate) mod runtime;
pub(crate) mod service;
