//! Primitive agent runner.
//!
//! The runner owns the provider loop after startup has accepted a prompt:
//! reconstruct session state, compose soul/state/history context, call the
//! provider with one `execute` capability, persist resulting events, and repeat
//! until the assistant reaches a terminal response.

#![deny(unsafe_code)]

pub(crate) mod agent;
pub(crate) mod context;
pub mod errors;
pub mod orchestrator;
pub(crate) mod pipeline;
pub mod profile_runtime;
pub(crate) mod types;

pub(crate) use agent::event_emitter::EventEmitter;
pub use errors::{RuntimeError, StopReason};
pub use orchestrator::orchestrator::Orchestrator;
pub use orchestrator::recovery::recover_incomplete_turns;
pub use orchestrator::session_manager::{ForkSessionResult, SessionFilter, SessionManager};
pub use orchestrator::session_reconstructor::ReconstructedState;
pub use profile_runtime::{ProfileRuntime, ResolvedHarnessSpec};
