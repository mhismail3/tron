//! Operation binding for the worktree worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(invocation.payload.clone());
    let ctx = deps.server_context.as_ref();
    match method {
        "worktree::get_status" => GetStatusOperation.run(params, ctx).await,
        "worktree::is_git_repo" => IsGitRepoOperation.run(params, ctx).await,
        "worktree::commit" => CommitOperation.run(params, ctx).await,
        "worktree::merge" => MergeOperation.run(params, ctx).await,
        "worktree::list" => ListOperation.run(params, ctx).await,
        "worktree::get_diff" => GetDiffOperation.run(params, ctx).await,
        "worktree::acquire" => AcquireOperation.run(params, ctx).await,
        "worktree::release" => ReleaseOperation.run(params, ctx).await,
        "worktree::list_session_branches" => ListSessionBranchesOperation.run(params, ctx).await,
        "worktree::get_committed_diff" => GetCommittedDiffOperation.run(params, ctx).await,
        "worktree::delete_branch" => DeleteBranchOperation.run(params, ctx).await,
        "worktree::prune_branches" => PruneBranchesOperation.run(params, ctx).await,
        "worktree::stage_files" => StageFilesOperation.run(params, ctx).await,
        "worktree::unstage_files" => UnstageFilesOperation.run(params, ctx).await,
        "worktree::discard_files" => DiscardFilesOperation.run(params, ctx).await,
        _ => Err(CapabilityError::Internal {
            message: format!("operation {method} is not worktree-owned"),
        }),
    }
}
