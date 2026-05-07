//! # cron
//!
//! Cron scheduling, job execution, and result delivery for the Tron agent.
//!
//! ## Architecture
//!
//! - **Config file** (`~/.tron/workspace/automations/automations.json`): Canonical job definitions
//! - **`SQLite`** (`log.db`): Runtime state (`next_run_at`, failures, runs)
//! - **Engine projection**: enabled jobs register live `cron_schedule` trigger definitions
//! - **Scheduler**: Timer-based loop that dispatches due jobs through `EngineTriggerRuntime`
//! - **Executor**: Payload execution via callback traits (shell, webhook, agent, system event)
//! - **Delivery**: Result notification (silent, WebSocket, APNS, webhook)
//!
//! Canonical `cron::*` functions are invoked through the engine. Schedule fires
//! target hidden `cron::scheduled_fire`, which preserves the existing overlap,
//! misfire, retry, timeout, delivery, and run-history behavior while adding
//! engine trigger/idempotency/ledger records.
//! `automations.json` and cron runtime SQLite remain durable truth for job
//! definitions and run history in this package; engine triggers are the live
//! invocation/watch surface.
//!
//! ## Invariants
//!
//! - **Corrupt-row handling is path-dependent**:
//!   - Single-id reads (`store::get_job`) are **fail-loud**: any corrupt JSON
//!     column returns `CronError::Database`, never a silent default.
//!   - Bulk iteration (`store::list_all_jobs`, `store::get_runs`,
//!     `store::get_stuck_candidates`) is **fail-skip**: the corrupt row is
//!     logged at `tracing::error!` and omitted from the result, so one bad
//!     row cannot hide the rest of the catalog. This is a deliberate trade-off
//!     between availability and strictness; revisit if a corrupt row becomes
//!     a silent-loss hazard.
//! - **Stale-id writes surface `NotFound`**: Every targeted `UPDATE`/`DELETE`
//!   by id in `store` checks `rows_affected` and returns `CronError::NotFound`
//!   on 0, so a GC or concurrent delete racing with a state write is
//!   observable. `upsert_job` and `insert_run` exempt themselves because
//!   their row count is always 1 by construction.
//! - **DB-before-memory**: Runtime state updates always write to SQLite first. If
//!   the DB write fails, the in-memory update is skipped to prevent divergence.
//! - **Allowlist-only restrictions**: `ToolRestrictions` uses `deny_unknown_fields` —
//!   legacy `deniedTools` JSON is rejected at parse time.
//! - **Full-file hashing**: The config watcher hashes the entire file, not a prefix.
//! - **Minimum timeout**: Shell (1s–3600s) and webhook (1s–300s) payloads reject 0s timeout.
//! - **Engine-attached fires**: In production, `main.rs` attaches the engine
//!   host before `start()`. When attached, scheduled fires must dispatch
//!   through `cron_schedule:<job_id>` rather than directly spawning execution.
//!   The direct start path remains for isolated scheduler tests that do not
//!   bootstrap the engine host.
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
