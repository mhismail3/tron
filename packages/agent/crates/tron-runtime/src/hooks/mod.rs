//! Async lifecycle hook engine for the Tron agent.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `engine` | Entry point — `HookEngine` manages hook lifecycle and dispatch |
//! | `registry` | Hook registration, priority ordering, event filtering |
//! | `handler` | Individual hook execution with timeout and error handling |
//! | `background` | Background hook queue with drain semantics |
//! | `discovery` | Finds hook definitions from `.claude/hooks/` and skills |
//! | `context` | Hook execution context (session, tool call, event data) |
//! | `errors` | Hook-specific error types |
//! | `types` | Shared types (hook config, timing, results) |
//!
//! ## Background Drain Ordering
//!
//! Background hooks are drained at two points: before a new prompt
//! (`agent_runner` pre-run) and before event reconstruction
//! (`session_manager` resume). This prevents stale hook state from
//! interfering with new agent runs or session reconstructions.

pub mod background;
pub mod context;
pub mod discovery;
pub mod engine;
pub mod errors;
pub mod handler;
pub mod registry;
pub mod types;
