//! # tron-cron
//!
//! Cron scheduling, job execution, and result delivery for the Tron agent.
//!
//! ## Architecture
//!
//! - **Config file** (`~/.tron/artifacts/cron/jobs.json`): Canonical job definitions
//! - **SQLite** (`tron.db`): Runtime state (next_run_at, failures, runs)
//! - **Scheduler**: Timer-based loop that fires due jobs
//! - **Executor**: Payload execution via callback traits (shell, webhook, agent, system event)
//! - **Delivery**: Result notification (silent, WebSocket, APNS, webhook)
//!
//! ## Crate Boundaries
//!
//! Depends on `tron-core`, `tron-events`, `tron-settings`.
//! Does NOT depend on `tron-runtime` or `tron-llm` — agent execution is
//! injected via the [`executor::AgentTurnExecutor`] trait, implemented
//! in `tron-agent/main.rs`.

#[allow(unused_results)]
pub mod clock;
#[allow(unused_results)]
pub mod config;
#[allow(unused_results)]
pub mod delivery;
#[allow(unused_results)]
pub mod errors;
#[allow(unused_results)]
pub mod executor;
#[allow(unused_results)]
pub mod migrations;
#[allow(unused_results)]
pub mod schedule;
#[allow(unused_results)]
pub mod scheduler;
#[allow(unused_results)]
pub mod store;
#[allow(unused_results)]
pub mod types;

// Re-exports for convenience
pub use clock::{Clock, SystemClock};
pub use errors::CronError;
pub use executor::{
    AgentTurnExecutor, AgentTurnResult, EventBroadcaster, ExecutorDeps, PushNotifier,
    SystemEventInjector,
};
pub use scheduler::CronScheduler;
pub use types::{
    CronConfig, CronJob, CronRun, Delivery, ExecutionOutput, JobRuntimeState, MisfirePolicy,
    OverlapPolicy, Payload, RunStatus, Schedule,
};
