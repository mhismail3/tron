//! Worker-independent execution for stable, reusable agents.
//!
//! `AgentExecutionService` is the sole process-local supervisor for core agent
//! assignments and wake intents. Durable truth remains in `tron.sqlite`; the
//! service owns only bounded in-flight guards and a notification fast path.
//! Startup interrupts orphaned attempts and releases wake leases, then drives
//! the same agent and transcript again. It never replaces an agent, assignment,
//! or hidden session after a crash.
//!
//! The module is deliberately unadvertised while the complete eight-tool
//! surface is assembled. It has no dependency on WorkerStore, WorkerRuntime,
//! worker roles, or mixed execution identifiers.

mod messages;
mod model;
mod runner;
mod service;

pub(crate) use model::{AgentExecutionRecovery, AssignmentExecutionCandidate};
pub(crate) use service::AgentExecutionService;
