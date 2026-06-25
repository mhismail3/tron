//! Procedural state provenance and inspection foundation.
//!
//! This domain owns inert procedural record projections for Phase 2 Slice 11A:
//! skills, rules, hooks, and procedures are represented as typed
//! `procedural_record` resources with provenance/eval/status metadata. The
//! provider-visible surface is limited to bounded read-only list/inspect
//! helpers called through `capability::execute`.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `projection` | Bounded/redacted provider-safe procedural record views |
//! | `service` | Resource-backed list/inspect validation and projections |
//!
//! # INVARIANT: no procedural activation
//!
//! Procedural records are custody and inspection evidence only. This domain
//! must not register triggers, inject prompt context, fire hooks, execute tools,
//! start workers/jobs/processes, install packages, learn behavior, or merge
//! results into conversation state.

mod projection;
pub(crate) mod service;

pub(crate) use crate::engine::{PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID};

pub(crate) const READ_SCOPE: &str = "procedural.read";
pub(crate) const SCHEMA_VERSION: &str = "tron.procedural_record.v1";

#[cfg(test)]
mod static_tests;
#[cfg(test)]
mod tests;
