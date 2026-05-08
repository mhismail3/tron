//! Operation binding for the git worker.

use super::{CloneOperation, Deps};
use crate::server::domains::bindings::operation_bindings;
use crate::server::domains::worktree::git_workflow::{
    ListLocalBranchesOperation, ListRemoteBranchesOperation, PushOperation, SyncMainOperation,
};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "clone" => |invocation, _deps| {
            CloneOperation.run(Some(invocation.payload.clone())).await
        },
        "sync_main" => |invocation, deps| {
            SyncMainOperation
                .run(Some(invocation.payload.clone()), &deps.worktree_deps)
                .await
        },
        "push" => |invocation, deps| {
            PushOperation
                .run(Some(invocation.payload.clone()), &deps.worktree_deps)
                .await
        },
        "list_local_branches" => |invocation, deps| {
            ListLocalBranchesOperation
                .run(Some(invocation.payload.clone()), &deps.worktree_deps)
                .await
        },
        "list_remote_branches" => |invocation, deps| {
            ListRemoteBranchesOperation
                .run(Some(invocation.payload.clone()), &deps.worktree_deps)
                .await
        },
    ];
}
