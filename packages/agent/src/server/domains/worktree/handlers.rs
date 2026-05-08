//! Operation binding for the worktree worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(invocation.payload.clone());
    match method {
        "worktree::get_status" => GetStatusOperation.run(params, deps).await,
        "worktree::is_git_repo" => IsGitRepoOperation.run(params, deps).await,
        "worktree::commit" => CommitOperation.run(params, deps).await,
        "worktree::merge" => MergeOperation.run(params, deps).await,
        "worktree::list" => ListOperation.run(params, deps).await,
        "worktree::get_diff" => GetDiffOperation.run(params, deps).await,
        "worktree::acquire" => AcquireOperation.run(params, deps).await,
        "worktree::release" => ReleaseOperation.run(params, deps).await,
        "worktree::list_session_branches" => ListSessionBranchesOperation.run(params, deps).await,
        "worktree::get_committed_diff" => GetCommittedDiffOperation.run(params, deps).await,
        "worktree::delete_branch" => DeleteBranchOperation.run(params, deps).await,
        "worktree::prune_branches" => PruneBranchesOperation.run(params, deps).await,
        "worktree::stage_files" => StageFilesOperation.run(params, deps).await,
        "worktree::unstage_files" => UnstageFilesOperation.run(params, deps).await,
        "worktree::discard_files" => DiscardFilesOperation.run(params, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("operation {method} is not worktree-owned"),
        }),
    }
}
