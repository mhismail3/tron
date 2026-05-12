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
//! | [`spawn`] | `SpawnSubagent` | Launch a child agent with a prompt, optional tool denial list, and configurable child depth |
//!
//! ## Invariants
//!
//! - Children are tracked by the orchestrator's `SubagentManager`
//!   ([`crate::domains::agent::runner::orchestrator::subagent_manager`]); their
//!   lifecycle events (`spawned`, `status_update`, `completed`,
//!   `failed`) flow through the normal event-persistence pipeline.
//! - Parent eligibility is bounded by `CreateAgentOpts::max_depth`
//!   ([`crate::domains::agent::runner::orchestrator::agent_factory`]).
//!   `SpawnSubagent.maxDepth` caps only the child agent's remaining
//!   child-spawn budget; `0` creates a leaf child.

pub mod spawn;
