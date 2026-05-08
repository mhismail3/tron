//! Canonical worktree engine functions.
//!
//! Client protocols reach this worker through engine triggers targeting
//! canonical `worktree::*` function ids. This root module owns registration and
//! workflow splits; `operations/` owns status, index, branch, diff, and
//! destructive worktree command bodies behind narrow `Deps`.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;

pub(crate) mod git_workflow;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let worktree_deps = Deps::from_engine(deps);
    super::domain_worker_module(
        "worktree",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, worktree_deps)?,
    )
}
