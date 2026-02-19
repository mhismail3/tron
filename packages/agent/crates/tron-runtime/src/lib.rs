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
//!
//! ## Crate Position
//!
//! Aggregation layer. Depends on: tron-core, tron-events, tron-llm, tron-tools,
//! tron-skills, tron-settings.
//! Depended on by: tron-server.

#![deny(unsafe_code)]

pub mod agent;
pub mod context;
pub mod errors;
pub mod guardrails;
pub mod hooks;
pub mod orchestrator;
pub mod pipeline;
pub mod tasks;
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
