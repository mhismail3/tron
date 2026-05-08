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
pub(super) use handlers::handle;

pub(crate) mod git_workflow;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let worktree_deps = Deps::from_engine(deps);
    let mut module = super::domain_worker_module(
        "worktree",
        contract::STREAM_TOPICS,
        Vec::new(),
        worktree_deps.clone(),
        super::worktree_handler,
    )?;
    module.functions.extend(
        contract::capabilities()?
            .into_iter()
            .map(|spec| {
                let handler = if matches!(
                    spec.method,
                    "worktree::finalize_session"
                        | "worktree::rebase_on_main"
                        | "worktree::start_merge"
                        | "worktree::list_conflicts"
                        | "worktree::resolve_conflict"
                        | "worktree::continue_merge"
                        | "worktree::abort_merge"
                        | "worktree::resolve_conflicts_with_subagent"
                ) {
                    super::git_workflow_handler
                } else {
                    super::worktree_handler
                };
                super::domain_function_registration(spec, worktree_deps.clone(), handler)
            })
            .collect::<crate::engine::Result<Vec<_>>>()?,
    );
    Ok(module)
}
