//! Read-only Git and worktree domain.
//!
//! This Phase 2 Slice 6A package restores source-control observation without
//! restoring source-control mutation. It detects the repository containing a
//! trusted runtime path, reports branch/upstream/dirty facts, and returns
//! bounded status/diff evidence through the existing `capability::execute`
//! primitive.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Read-only `git::*` function contracts and schemas |
//! | `handlers` | Operation-key binding table |
//! | `service` | Trusted path resolution, Git command execution, and truncation |
//! | `types` | Small request/result helper types |
//!
//! # INVARIANT: git restoration is read-only
//!
//! This domain must not stage, commit, merge, rebase, reset, push, delete
//! branches, resolve conflicts, or mutate repository state. All paths resolve
//! from trusted working-directory runtime metadata, reject absolute paths and
//! traversal, and fail closed when the discovered worktree root escapes that
//! trusted root.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
pub(crate) mod service;
mod types;

pub(crate) const WORKER: &str = "git";
pub(crate) const READ_SCOPE: &str = "git.read";

pub(crate) const STATUS_FUNCTION: &str = "git::status";
pub(crate) const DIFF_FUNCTION: &str = "git::diff";

#[derive(Clone)]
pub(crate) struct Deps;

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainRegistrationContext) -> Self {
        Self
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
