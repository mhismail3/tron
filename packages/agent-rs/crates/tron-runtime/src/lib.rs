//! # tron-runtime
//!
//! Agent execution loop, session management, and orchestration.
//!
//! - **Agent**: Holds provider, tools, hooks, context manager. Runs the turn loop.
//! - **Turn runner**: Build context → call LLM → process stream → execute tools → record events
//! - **Tool executor**: Pre/post hooks, guardrails, cancellation token support
//! - **Stream processor**: Consumes `Stream<StreamEvent>`, accumulates content blocks
//! - **Agent runner**: High-level: skill injection, user content building, interrupt handling
//! - **Orchestrator**: Multi-session management with event broadcasting

#![deny(unsafe_code)]

pub mod agent;
pub mod errors;
pub mod orchestrator;
pub mod pipeline;
pub mod types;

// Re-export main public API
pub use agent::event_emitter::EventEmitter;
pub use agent::tron_agent::TronAgent;
pub use errors::{RuntimeError, StopReason};
pub use orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
pub use orchestrator::agent_runner::run_agent;
pub use orchestrator::orchestrator::Orchestrator;
pub use orchestrator::session_manager::{ForkSessionResult, SessionFilter, SessionManager};
pub use orchestrator::session_reconstructor::ReconstructedState;
pub use types::{AgentConfig, ReasoningLevel, RunContext, RunResult, TurnResult};
