//! Agent prompt runtime support owned by canonical engine functions.
//!
//! The production `agent.prompt` path is no longer an RPC handler. JSON-RPC is
//! a marker-only transport trigger into `agent::prompt`, while this module owns
//! the reusable prompt bootstrap, run spawning, queue drain, and completion
//! helpers used by canonical agent functions and test fixtures.

pub(crate) mod runtime;
pub(crate) mod service;
