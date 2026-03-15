//! # tron-cron
//!
//! Cron scheduling, job execution, and result delivery for the Tron agent.
//!
//! ## Architecture
//!
//! - **Config file** (`~/.tron/artifacts/automations.json`): Canonical job definitions
//! - **`SQLite`** (`tron.db`): Runtime state (`next_run_at`, failures, runs)
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

#[path = "runtime/clock.rs"]
pub mod clock;
#[path = "domain/config.rs"]
pub mod config;
#[path = "execution/delivery.rs"]
pub mod delivery;
pub mod errors;
#[path = "execution/executor.rs"]
pub mod executor;
pub mod impls;
#[path = "runtime/migrations.rs"]
pub mod migrations;
#[path = "domain/schedule.rs"]
pub mod schedule;
#[path = "runtime/scheduler.rs"]
pub mod scheduler;
#[path = "runtime/store.rs"]
pub mod store;
#[path = "domain/types.rs"]
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
    OverlapPolicy, Payload, RunStatus, Schedule, ToolRestrictions,
};
