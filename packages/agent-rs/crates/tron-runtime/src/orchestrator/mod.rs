//! Orchestrator modules — session management and multi-session coordination.

pub mod agent_factory;
pub mod agent_runner;
pub mod event_persister;
#[allow(clippy::module_inception)]
pub mod orchestrator;
pub mod session_context;
pub mod session_manager;
pub mod session_reconstructor;
