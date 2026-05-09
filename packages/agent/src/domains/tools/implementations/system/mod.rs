//! # tools/system — process and shell tools
//!
//! Tool implementations that spawn child processes or manage long-running
//! background jobs. Every process crosses the `ProcessRunner` trait
//! boundary ([`crate::domains::tools::implementations::traits`]), so tests inject a stub runner
//! that returns canned output.
//!
//! ## Submodules
//!
//! | Module          | Tool        | Content |
//! |-----------------|-------------|---------|
//! | [`bash`]        | `Bash`      | Execute shell commands with streaming stdout/stderr, optional timeout, optional background mode |
//! | [`manage_process`] | `ManageJob` | Inspect, wait-on, kill, and stream stdout of background jobs launched by `Bash` |
//! | [`wait`]        | `Wait`      | Block until a specific process or subagent reaches a terminal state |
//! | [`sandbox`]     | —           | OS-level process sandboxing helpers (macOS `sandbox-exec` profile generation) |
//!
//! ## Invariants
//!
//! - Background jobs launched by `Bash` are tracked by the orchestrator's
//!   process manager ([`crate::domains::agent::runner::orchestrator::process_manager`]);
//!   [`manage_process`] calls go through that registry so orphaned PIDs
//!   don't accumulate.
//! - `Wait` is capped by a wall-clock timeout (default configurable) so
//!   a hung subagent can't stall the parent turn indefinitely.
//! - [`sandbox`] profiles are additive — a tighter parent profile always
//!   wins over a looser child profile.

pub mod bash;
pub mod manage_process;
pub mod sandbox;
pub mod wait;
