//! Operation binding for the worktree worker.

use super::operations::*;
use super::*;
use crate::server::domains::bindings::operation_bindings;
use crate::server::domains::worktree::git_workflow::{
    AbortMergeOperation, ContinueMergeOperation, FinalizeSessionOperation, ListConflictsOperation,
    RebaseOnMainOperation, ResolveConflictOperation, ResolveConflictsWithSubagentOperation,
    StartMergeOperation,
};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "get_status" => |invocation, deps| {
            GetStatusOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "is_git_repo" => |invocation, deps| {
            IsGitRepoOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "commit" => |invocation, deps| {
            CommitOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "merge" => |invocation, deps| {
            MergeOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "list" => |invocation, deps| {
            ListOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "get_diff" => |invocation, deps| {
            GetDiffOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "acquire" => |invocation, deps| {
            AcquireOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "release" => |invocation, deps| {
            ReleaseOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "list_session_branches" => |invocation, deps| {
            ListSessionBranchesOperation
                .run(Some(invocation.payload.clone()), deps)
                .await
        },
        "get_committed_diff" => |invocation, deps| {
            GetCommittedDiffOperation
                .run(Some(invocation.payload.clone()), deps)
                .await
        },
        "delete_branch" => |invocation, deps| {
            DeleteBranchOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "prune_branches" => |invocation, deps| {
            PruneBranchesOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "stage_files" => |invocation, deps| {
            StageFilesOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "unstage_files" => |invocation, deps| {
            UnstageFilesOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "discard_files" => |invocation, deps| {
            DiscardFilesOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "finalize_session" => |invocation, deps| {
            FinalizeSessionOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "rebase_on_main" => |invocation, deps| {
            RebaseOnMainOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "start_merge" => |invocation, deps| {
            StartMergeOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "list_conflicts" => |invocation, deps| {
            ListConflictsOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "resolve_conflict" => |invocation, deps| {
            ResolveConflictOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "continue_merge" => |invocation, deps| {
            ContinueMergeOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "abort_merge" => |invocation, deps| {
            AbortMergeOperation.run(Some(invocation.payload.clone()), deps).await
        },
        "resolve_conflicts_with_subagent" => |invocation, deps| {
            ResolveConflictsWithSubagentOperation
                .run(Some(invocation.payload.clone()), deps)
                .await
        },
    ];
}
