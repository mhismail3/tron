//! Read-only git/worktree foundation.
//!
//! This domain owns the Phase 2 Slice 6A source-control foundation: bounded,
//! read-only status and tracked diff evidence for repositories under trusted
//! working-directory metadata. It deliberately does not stage, commit, merge,
//! rebase, reset, push, delete branches, resolve conflicts, create PRs, or add
//! native iOS SourceChanges UI.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | `git::status` and `git::diff` read-only contracts |
//! | `handlers` | Operation-key binding table |
//! | `service` | Trusted path resolution, git command reads, porcelain parsing |
//! | `types` | Serializable status/diff evidence DTOs |
//!
//! # INVARIANT: git is read-only in Slice 6A
//!
//! Git commands in this domain must be read-oriented (`rev-parse`, `status`,
//! `diff`) and run with optional index locking disabled. Mutating git/worktree
//! behavior requires a later slice with authority, approvals, resources,
//! rollback, replay evidence, and tests.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
pub(crate) mod service;
pub(crate) mod types;

pub(crate) const WORKER: &str = "git";
pub(crate) const READ_SCOPE: &str = "git.read";
const STREAM_TOPICS: &[&str] = &[];

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
        STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
