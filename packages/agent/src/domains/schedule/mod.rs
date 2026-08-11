//! Durable time-triggered agent work.
//!
//! Scheduling is a fixed Engine capability: it stores an agent task and admits
//! occurrences at RFC 5545 instants. It does not embed a worker or model policy.
//! The execution boundary consumes queued occurrences and resolves their target
//! as a reusable agent, fresh agent, or namespaced capability registry entry.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `contract` | Closed action union and canonical schedule/occurrence DTOs. |
//! | `recurrence` | Bounded RFC 5545 validation and IANA-zone expansion. |
//! | `service` | Revision-safe commands, durable reconciliation, and occurrence lifecycle. |
//!
//! ## Invariants
//!
//! - Schedule targets are exactly `reusable_agent`, `fresh_agent`, or
//!   `capability`. A capability is an opaque namespaced registry/package
//!   entrypoint; schedules never encode workers or choose whether the registry
//!   implements it as a direct module, fixed service, or script.
//! - Every definition and occurrence retains the exact Engine-authored
//!   authority snapshot admitted at creation/retargeting. Dispatch may narrow
//!   or reject that grant but never derives broader authority from elapsed time.
//! - Recurrence evaluation always uses the stored IANA timezone and an explicit
//!   floating local `DTSTART`; machine-local timezone state is never consulted.
//! - One SQLite transaction both advances a durable cursor and admits every
//!   occurrence produced by that reconciliation, so restart replay cannot
//!   duplicate work.
//! - Scheduled occurrence keys are a deterministic function of schedule ID and
//!   UTC instant. Manual occurrences use the caller's idempotency key.
//! - All mutations use revision compare-and-set. Deletion is a tombstone so
//!   occurrence audit remains readable.
//! - Expansion and catch-up are bounded. A rule which exceeds the documented
//!   scan bound fails closed without moving its cursor.

pub(crate) mod contract;
pub(crate) mod recurrence;
pub(crate) mod service;

#[cfg(test)]
mod tests;
