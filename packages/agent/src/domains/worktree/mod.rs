//! Canonical worktree engine functions.
//!
//! Client protocols reach this worker through engine triggers targeting
//! canonical `worktree::*` function ids. This root module owns registration and
//! workflow splits; `operations/` owns status, index, branch, diff summary,
//! full diff, and destructive worktree command bodies behind narrow `Deps`.
//! Destructive file discard accepts only repository-relative paths and pauses
//! for user approval before deleting untracked files or restoring tracked
//! changes. Read-only inspection contracts are intentionally tagged and described for the
//! model-facing `capability::execute` resolver, while the trusted current
//! session binding remains owned by the capability orchestration layer.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub use implementation::*;

pub(crate) mod git_workflow;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let worktree_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "worktree",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, worktree_deps)?,
    )
}
