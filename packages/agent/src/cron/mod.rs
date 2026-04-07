//! # cron
//!
//! Cron scheduling, job execution, and result delivery for the Tron agent.
//!
//! ## Architecture
//!
//! - **Config file** (`~/.tron/workspace/automations/automations.json`): Canonical job definitions
//! - **`SQLite`** (`log.db`): Runtime state (`next_run_at`, failures, runs)
//! - **Scheduler**: Timer-based loop that fires due jobs
//! - **Executor**: Payload execution via callback traits (shell, webhook, agent, system event)
//! - **Delivery**: Result notification (silent, WebSocket, APNS, webhook)
//!
//! ## Invariants
//!
//! - **Fail-loud on corrupt data**: `store::row_to_job()` returns an error if any
//!   JSON column is corrupt. Jobs with invalid data are skipped, not silently defaulted.
//! - **DB-before-memory**: Runtime state updates always write to SQLite first. If
//!   the DB write fails, the in-memory update is skipped to prevent divergence.
//! - **Allowlist-only restrictions**: `ToolRestrictions` uses `deny_unknown_fields` —
//!   legacy `deniedTools` JSON is rejected at parse time.
//! - **Full-file hashing**: The config watcher hashes the entire file, not a prefix.
//! - **Minimum timeout**: Shell (1s–3600s) and webhook (1s–300s) payloads reject 0s timeout.
//!
//! ## Module Boundaries
//!
//! Depends on `core`, `events`, `settings`.
//! Does NOT depend on `runtime` or `llm` — agent execution is
//! injected via the [`executor::AgentTurnExecutor`] trait, implemented
//! in `main.rs`.

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
pub use executor::{AgentTurnResult, ExecutorDeps};
pub use scheduler::CronScheduler;
pub use types::{
    CronConfig, CronJob, CronRun, Delivery, ExecutionOutput, JobRuntimeState, MisfirePolicy,
    OverlapPolicy, Payload, RunStatus, Schedule, ToolRestrictions,
};
