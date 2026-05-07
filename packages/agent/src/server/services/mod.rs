//! Server-local services used by canonical engine capabilities.
//!
//! These modules are runtime and domain helpers, not public transports. The
//! JSON-RPC layer may depend on [`context`] to access shared server state, but
//! executable behavior is owned by `server::capabilities` and these services.

pub(crate) mod agent_commands;
pub(crate) mod agent_runtime;
pub(crate) mod auth_flows;
pub(crate) mod client_logs;
pub mod context;
pub(crate) mod context_commands;
pub(crate) mod context_queries;
pub(crate) mod context_service;
pub(crate) mod events_wire;
pub(crate) mod filesystem_service;
pub(crate) mod git_service;
pub(crate) mod interactive_tool_enrichment;
pub(crate) mod memory_retain;
pub(crate) mod model_catalog;
pub(crate) mod notification_inbox;
pub(crate) mod prompt_queue;
pub(crate) mod sandbox_service;
pub(crate) mod session_commands;
pub mod session_context;
pub(crate) mod session_queries;
pub(crate) mod session_reconstruct;
pub(crate) mod skill_state;
#[cfg(test)]
pub(crate) mod test_support;
pub(crate) mod voice_notes_service;
