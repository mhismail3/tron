//! Primitive agent loop.
//!
//! The loop owns provider execution after startup has accepted a prompt:
//! reconstruct session state, compose soul/state/history context, call the
//! provider with one `execute` capability, persist resulting events, and repeat
//! until the assistant reaches a terminal response.

#![deny(unsafe_code)]

pub mod capability_invocation_executor;
pub mod compaction_handler;
pub mod errors;
pub mod event_emitter;
pub mod orchestrator;
pub(crate) mod pipeline;
pub mod primitive_surface;
pub mod profile_runtime;
pub mod stream_processor;
mod stream_state;
pub mod tron_agent;
pub mod turn_runner;
pub(crate) mod types;

pub(crate) use event_emitter::EventEmitter;
pub use orchestrator::core::Orchestrator;
pub use orchestrator::recovery::recover_incomplete_turns;
pub use orchestrator::session_manager::{SessionFilter, SessionManager};
pub use profile_runtime::ProfileRuntime;
