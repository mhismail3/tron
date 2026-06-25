//! Durable scheduling, reminder, automation, and background-run records.
//!
//! This Slice 12 domain owns schedules, timezone policy, missed-run handling,
//! explicit due-trigger evaluation, run records, cancellation, and bounded
//! inspection projections. It does not start a polling loop, run feature work,
//! deliver APNs/device notifications, launch workers/processes/network work, or
//! merge background results into conversation state. Feature domains consume
//! `schedule_run` records and own the work those records describe.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `errors` | Domain-local error helpers |
//! | `service` | Create/list/inspect/cancel/fire-due behavior |
//! | `support` | Payload readers, authority/scope helpers, projection helpers |
//! | `types` | Serializable schedule and run record schemas |
//! | `tests` | Clock injection, missed-run, cancellation, authority, and schema tests |
//!
//! # INVARIANT: schedules are explicit durable records
//!
//! Scheduler work must enter through schedule resources and explicit fire-due
//! evaluation. There are no hidden cron tables, uncontrolled background tasks,
//! broad provider-visible target execution, package/worker launch, APNs
//! delivery, browser/search/login/crawl behavior, or autonomous planning
//! semantics in this domain.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod errors;
mod planning;
mod projection;
pub(crate) mod service;
mod support;
mod types;

pub(crate) use crate::engine::{
    SCHEDULE_KIND, SCHEDULE_RUN_KIND, SCHEDULE_RUN_SCHEMA_ID, SCHEDULE_SCHEMA_ID,
};

pub(crate) const WORKER: &str = "scheduler";
pub(crate) const SCHEDULER_LIFECYCLE_TOPIC: &str = "scheduler.lifecycle";
pub(crate) const READ_SCOPE: &str = "scheduler.read";
pub(crate) const WRITE_SCOPE: &str = "scheduler.write";
pub(crate) const FIRE_SCOPE: &str = "scheduler.fire";

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[SCHEDULER_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
