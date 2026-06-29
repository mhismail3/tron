//! Git and worktree domain.
//!
//! This Phase 2 package restores source-control observation plus the narrow
//! Slice 6C Git staged-index commit, Slice 6D branch-start, and Slice 6E
//! branch-inventory foundations. It detects the repository containing a trusted
//! runtime path, reports branch/upstream/dirty facts, returns bounded
//! status/diff and branch-list evidence, stages/unstages explicit relative
//! paths, creates one guarded single-parent commit from the already-staged
//! index, and creates one local branch at the expected `HEAD` before moving the
//! symbolic `HEAD` through a guarded ref/OID check in the existing
//! `capability::execute` primitive. Phase 3 Slice 24A declares these existing
//! operations in the pending-review `file_git_module` manifest and maps them to
//! exact Git/resource/file-root authority without broad implicit state.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `branch_inventory` | Read-only bounded local branch inventory evidence |
//! | `branch_start` | Local branch creation plus symbolic `HEAD` movement |
//! | `commit` | Staged-index commit implementation and evidence |
//! | `contract` | Read and index-mutation `git::*` function contracts and schemas |
//! | `handlers` | Operation-key binding table |
//! | `mutation` | Index-only stage/unstage implementation and evidence |
//! | `service` | Trusted path resolution, Git command execution, and truncation |
//! | `types` | Small request/result helper types |
//!
//! # INVARIANT: Git mutation is staged-state only
//!
//! This domain must not merge, rebase, reset, push, delete/rename/reset branches,
//! resolve conflicts, or mutate repository files. Stage/unstage operations only mutate
//! the Git index after validating trusted working-directory metadata, explicit
//! relative paths, expected HEAD freshness, path existence, and path-scoped
//! conflict state. Commit operations create exactly one commit from the
//! already-staged index on the current named branch by rechecking expected HEAD
//! and expected index-tree, writing the commit object with exactly that
//! parent/tree, and advancing the branch ref with guarded `update-ref` while
//! the worktree's symbolic `HEAD` is locked and reverified. Branch-start
//! operations create exactly one missing local branch at the current expected
//! `HEAD`, then move symbolic `HEAD` to that new branch only after rechecking the
//! old symbolic ref and OID while `HEAD` is locked. They do this without
//! checkout, hooks, remotes, index mutation, or worktree file updates; if
//! symbolic `HEAD` movement fails, the just-created ref is removed only when it
//! still points at the expected OID. Caller-controlled status/diff byte limits
//! affect evidence only, never mutation eligibility. Branch inventory is
//! read-only: it enumerates local `refs/heads/*`, computes ahead/behind only
//! against already-present local upstream refs, reports oversized last-commit
//! metadata as truncated row evidence, and never fetches, switches, creates,
//! deletes, renames, or contacts remotes.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod branch_inventory;
pub(crate) mod branch_start;
pub(crate) mod commit;
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
