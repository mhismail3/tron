//! Inspect-only module manifest registry.
//!
//! Phase 3 Slice 23A introduces a source-backed registry for first-party module
//! identity and declarations. The provider-visible surface is limited to
//! `capability::execute` operation values `module_list` and `module_inspect`.
//! Both operations read `module_manifest` resources from the generic engine
//! resource store, revalidate stored kind/schema/scope/payload shape, and
//! return bounded projections without exposing raw manifests, local paths,
//! commands, secrets, grants, authority ids, or token-like material.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `manifest` | Payload schema version, bounds, and stored-manifest validation |
//! | `projection` | Provider-safe summary and detail projections |
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
pub(crate) mod service;

pub(crate) use crate::engine::{MODULE_MANIFEST_KIND, MODULE_MANIFEST_SCHEMA_ID};

pub(crate) const WORKER: &str = "module_registry";
pub(crate) const READ_SCOPE: &str = "module_registry.read";
pub(crate) const SCHEMA_VERSION: &str = crate::engine::MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION;

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(WORKER, &[], Vec::new())
}

#[cfg(test)]
mod tests;
