//! # subagents
//!
//! Programmatic subagent definitions — specialized child agents that the
//! server spawns internally for specific workflows (distinct from
//! LLM-initiated `SpawnSubagent` calls).
//!
//! Each submodule owns a single, named subagent: its system prompt, the
//! tool allowlist, and the wire-up helper that shapes a
//! [`SubsessionConfig`](crate::runtime::orchestrator::subagent_manager::SubsessionConfig)
//! and hands it to the `SubagentManager`.
//!
//! ## Submodules
//!
//! - **`conflict_resolver`** — drives git merge conflict resolution
//!   inside a session's worktree (git workflow Phase 7).
//!
//! ## Module Position
//!
//! Depends on: core, events, runtime::orchestrator, worktree.
//! Depended on by: server::rpc::handlers.

#![deny(unsafe_code)]

pub mod conflict_resolver;
