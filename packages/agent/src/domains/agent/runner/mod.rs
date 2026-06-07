//! Primitive agent runner.
//!
//! The runner owns the provider loop after startup has accepted a prompt:
//! reconstruct session state, compose soul/state/history context, call the
//! provider with one `execute` capability, persist resulting events, and repeat
//! until the assistant reaches a terminal response.

#![deny(unsafe_code)]

pub mod agent;
pub mod context;
pub mod errors;
pub mod orchestrator;
pub mod pipeline;
pub mod profile_runtime;
pub mod types;

// Re-export main public API
pub use agent::event_emitter::EventEmitter;
pub use agent::tron_agent::{AgentDeps, TronAgent};
pub use errors::{RuntimeError, StopReason};
pub use orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
pub use orchestrator::agent_runner::run_agent;
pub use orchestrator::orchestrator::Orchestrator;
pub use orchestrator::session_manager::{ForkSessionResult, SessionFilter, SessionManager};
pub use orchestrator::session_reconstructor::ReconstructedState;
pub use profile_runtime::{
    ProcessExecutionPlan, ProfileRuntime, ResolvedHarnessSpec, SessionExecutionPlan,
    SessionPlanRequest,
};
pub use types::{AgentConfig, ReasoningLevel, RunContext, RunResult, TurnResult};
