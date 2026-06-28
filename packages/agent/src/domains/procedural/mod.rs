//! Procedural state provenance and inspection foundation.
//!
//! This domain owns inert procedural module-pack metadata for skills, rules,
//! hooks, and procedures. Definitions are represented as typed
//! `procedural_record` resources with provenance/eval/status/review metadata,
//! and activation/deactivation/rollback review is represented as separate
//! request/decision resources. The provider-visible surface is limited to
//! bounded record/list/inspect helpers called through `capability::execute`.
//! Projection inputs are revalidated for stored kind/schema/scope/lifecycle
//! plus scalar/hash fields that remain visible to providers.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `projection` | Bounded/redacted provider-safe procedural resource views |
//! | `service` | Resource-backed record/list/inspect validation and projections |
//!
//! # INVARIANT: no procedural activation
//!
//! Procedural records and activation decisions are custody/review evidence
//! only. This domain must not register triggers, inject prompt context, fire
//! hooks, execute tools, start workers/jobs/processes, install packages, learn
//! behavior, or merge results into conversation state. Decision evidence must
//! match the stored request action, and rollback/deactivation approvals must
//! carry the corresponding proof refs. Procedural module registry seeds are
//! metadata-only manifest evidence; this domain must not add repo-managed
//! `packages/agent/skills`, package `SKILL.md` assets, skill-copy/bootstrap
//! registries, or hidden skill prompt-context injection. Static containment
//! tests scan compacted code-like identifiers for singular/plural registry,
//! loader, bootstrap, and prompt context forms while preserving allowed
//! metadata-only module-registry evidence.

mod projection;
pub(crate) mod service;

pub(crate) use crate::engine::{
    PROCEDURAL_ACTIVATION_DECISION_KIND, PROCEDURAL_ACTIVATION_DECISION_SCHEMA_ID,
    PROCEDURAL_ACTIVATION_REQUEST_KIND, PROCEDURAL_ACTIVATION_REQUEST_SCHEMA_ID,
    PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID,
};

pub(crate) const READ_SCOPE: &str = "procedural.read";
pub(crate) const WRITE_SCOPE: &str = "procedural.write";
pub(crate) const SCHEMA_VERSION: &str = "tron.procedural_record.v1";
pub(crate) const ACTIVATION_REQUEST_SCHEMA_VERSION: &str = "tron.procedural_activation_request.v1";
pub(crate) const ACTIVATION_DECISION_SCHEMA_VERSION: &str =
    "tron.procedural_activation_decision.v1";

#[cfg(test)]
mod projection_scalar_tests;
#[cfg(test)]
mod static_tests;
#[cfg(test)]
mod tests;
