//! Inspect-only module manifest registry.
//!
//! Phase 3 Slice 23A introduces a source-backed registry for first-party module
//! identity and declarations. Domain registration owns the ordered built-in
//! manifest composition, including the filesystem/Git, jobs/program-execution,
//! memory, procedural, web research, notification delivery, and
//! import/repository/update module packs. This domain owns stored-manifest
//! validation and projection without becoming an activation surface. The
//! provider-visible surface is limited to `capability::execute` operation
//! values `module_list` and `module_inspect`. Both operations read
//! `module_manifest` resources from the generic engine resource store,
//! revalidate stored kind/schema/scope/payload shape, and return bounded
//! projections without exposing raw manifests, local paths, commands, secrets,
//! grants, authority ids, or token-like material.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `manifest` | Payload bounds and stored-manifest validation |
//! | `projection` | Provider-safe summary and detail projections |
//! | `resource` | Domain-owned kind, schema, retention, and redaction contract |
//! | `service` | Resource-backed list/inspect operations and grant checks |
//! | `tests` | Schema, seed, redaction, authority, scope, and side-effect coverage |
//!
//! # INVARIANT: registry inspection is not module activation
//!
//! This domain must never install modules, enable modules, execute module
//! behavior, resolve dependencies, access networks, run commands, register
//! public `/engine` methods, or write resources from list/inspect. Later slices
//! own authoring, validation reports, install gates, activation lifecycle,
//! runtime supervision, dependency policy, and cockpit UI.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod manifest;
mod projection;
mod resource;
pub(crate) mod service;

pub(in crate::domains) use resource::resource_type_definition;

pub(in crate::domains) const WORKER: &str = "module_registry";
pub(in crate::domains) const READ_SCOPE: &str = "module_registry.read";
pub(in crate::domains) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(in crate::domains) const MODULE_MANIFEST_KIND: &str = "module_manifest";
pub(in crate::domains) const MODULE_MANIFEST_SCHEMA_ID: &str = "tron.resource.module_manifest.v1";
pub(in crate::domains) const SCHEMA_VERSION: &str = "tron.module_manifest.v1";

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(WORKER, &[], Vec::new())
}

#[cfg(test)]
mod tests;
