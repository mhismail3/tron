//! # subagents
//!
//! Programmatic subagent definitions — specialized child agents that the
//! server spawns internally for specific workflows (distinct from
//! LLM-initiated `agent::spawn_subagent` capability executions).
//!
//! Each submodule owns a single, named subagent: its system prompt, the
//! tool allowlist, and the wire-up helper that shapes a
//! [`SubsessionConfig`](crate::domains::agent::runner::orchestrator::subagent_manager::SubsessionConfig)
//! and hands it to the `SubagentManager`.
//!
//! ## Submodules
//!
//! - **`conflict_resolver`** — drives git merge conflict resolution
//!   inside a session's worktree (git workflow Phase 7). Non-blocking
//!   subsession; a post-spawn auto-abort watcher enforces a wall-clock
//!   bound (derived from `SubsessionConfig::timeout_ms`) by cancelling
//!   the subagent before reconciling the merge state.
//!
//! ## Module Position
//!
//! Depends on: core, events, runtime::orchestrator, worktree.
//! Depended on by: canonical worktree capabilities.

#![deny(unsafe_code)]

pub mod conflict_resolver;
