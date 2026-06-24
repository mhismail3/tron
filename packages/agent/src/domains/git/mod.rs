//! Git and worktree domain.
//!
//! This Phase 2 package restores source-control observation plus the narrow
//! Slice 6B Git index mutation foundation. It detects the repository
//! containing a trusted runtime path, reports branch/upstream/dirty facts,
//! returns bounded status/diff evidence, and stages/unstages explicit relative
//! paths through the existing `capability::execute` primitive.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Read and index-only write `git::*` function contracts and schemas |
//! | `handlers` | Operation-key binding table |
//! | `mutation` | Index-only stage/unstage implementation and evidence |
//! | `service` | Trusted path resolution, Git command execution, and truncation |
//! | `types` | Small request/result helper types |
//!
//! # INVARIANT: git mutation is index-only
//!
//! This domain must not commit, merge, rebase, reset, push, delete branches,
//! resolve conflicts, or mutate repository files. Stage/unstage operations only
//! mutate the Git index after validating trusted working-directory metadata,
//! explicit relative paths, expected HEAD freshness, path existence, and
//! path-scoped conflict state.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod contract;
mod handlers;
pub(crate) mod mutation;
pub(crate) mod service;
mod types;

pub(crate) const WORKER: &str = "git";
pub(crate) const GIT_LIFECYCLE_TOPIC: &str = "git.lifecycle";
pub(crate) const READ_SCOPE: &str = "git.read";
pub(crate) const WRITE_SCOPE: &str = "git.write";
const STREAM_TOPICS: &[&str] = &[GIT_LIFECYCLE_TOPIC];

pub(crate) const STATUS_FUNCTION: &str = "git::status";
pub(crate) const DIFF_FUNCTION: &str = "git::diff";
pub(crate) const STAGE_FUNCTION: &str = "git::stage";
pub(crate) const UNSTAGE_FUNCTION: &str = "git::unstage";

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
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
