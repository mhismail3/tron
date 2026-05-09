//! # tools/subagent — agent-spawning tools
//!
//! Tools that launch a child agent as a bounded sub-computation. The
//! child inherits the parent's workspace, settings, and (optionally) a
//! restricted tool set; it runs on its own turn loop and reports back
//! via `subagent.*` events.
//!
//! ## Submodules
//!
//! | Module   | Tool             | Content |
//! |----------|------------------|---------|
//! | [`spawn`] | `SpawnSubagent` | Launch a child agent with a prompt, optional tool denial list, and configurable max depth |
//!
//! ## Invariants
//!
//! - Children are tracked by the orchestrator's `SubagentManager`
//!   ([`crate::domains::agent::runner::orchestrator::subagent_manager`]); their
//!   lifecycle events (`spawned`, `status_update`, `completed`,
//!   `failed`) flow through the normal event-persistence pipeline.
//! - Depth is bounded by `CreateAgentOpts::max_depth`
//!   ([`crate::domains::agent::runner::orchestrator::agent_factory`]); a child at
//!   depth `N` can only spawn further children when `max_depth > N`,
//!   preventing infinite recursion.

pub mod spawn;
