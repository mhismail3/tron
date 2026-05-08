//! Canonical function inventory for the worktree domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "worktree::get_status",
    "worktree::is_git_repo",
    "worktree::commit",
    "worktree::merge",
    "worktree::list",
    "worktree::get_diff",
    "worktree::acquire",
    "worktree::release",
    "worktree::list_session_branches",
    "worktree::get_committed_diff",
    "worktree::finalize_session",
    "worktree::delete_branch",
    "worktree::prune_branches",
    "worktree::stage_files",
    "worktree::unstage_files",
    "worktree::discard_files",
    "worktree::rebase_on_main",
    "worktree::start_merge",
    "worktree::list_conflicts",
    "worktree::resolve_conflict",
    "worktree::continue_merge",
    "worktree::abort_merge",
    "worktree::resolve_conflicts_with_subagent",
];
