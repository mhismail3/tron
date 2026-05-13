//! # runtime
//!
//! Agent execution loop, session management, and orchestration.
//!
//! - **Agent**: Holds provider, capabilities, hooks, context manager. Runs the turn loop.
//! - **Turn runner**: Build context → call LLM → process stream → execute capabilities → record events
//! - **ModelCapability executor**: Pre/post hooks, guardrails, cancellation token support
//! - **Stream processor**: Consumes `Stream<StreamEvent>`, accumulates content blocks
//! - **Agent runner**: High-level: skill injection, user content building, interrupt handling
//! - **Memory**: User-memory loader for `~/.tron/memory/MEMORY.md` + `rules/*.md` (fingerprint-gated, per-turn).
//! - **Orchestrator**: Multi-session management with event broadcasting
//! - **Profile runtime**: Atomically compiled profile snapshots and session/process plans
//!
//! ## Module Position
//!
//! Aggregation layer. Depends on: core, events, llm, capabilities,
//! skills, settings.
//! Depended on by: server.

#![deny(unsafe_code)]

pub mod agent;
pub mod context;
pub mod errors;
pub mod guardrails;
pub mod hooks;
pub mod memory;
pub mod orchestrator;
pub mod pipeline;
pub mod profile_runtime;
pub mod subagents;
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
