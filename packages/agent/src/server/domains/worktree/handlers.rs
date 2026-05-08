//! Operation binding for the worktree worker.

use super::operations::*;
use super::*;

pub(crate) fn function_registrations(
    specs: Vec<crate::server::domains::catalog::CapabilitySpec>,
    deps: Deps,
) -> crate::engine::Result<Vec<crate::server::domains::DomainFunctionRegistration>> {
    specs
        .into_iter()
        .map(|spec| function_registration(spec, deps.clone()))
        .collect()
}

pub(crate) fn function_registration(
    spec: crate::server::domains::catalog::CapabilitySpec,
    deps: Deps,
) -> crate::engine::Result<crate::server::domains::DomainFunctionRegistration> {
    Ok(crate::server::domains::DomainFunctionRegistration {
        definition: crate::server::domains::catalog::function_definition_for_capability(&spec),
        handler: handler_for_operation(spec.operation_key, deps),
    })
}

pub(crate) fn handler_for_operation(
    operation_key: impl Into<String>,
    deps: Deps,
) -> std::sync::Arc<dyn crate::engine::InProcessFunctionHandler> {
    std::sync::Arc::new(FunctionHandler {
        operation_key: operation_key.into(),
        deps,
    })
}

struct FunctionHandler {
    operation_key: String,
    deps: Deps,
}

#[async_trait::async_trait]
impl crate::engine::InProcessFunctionHandler for FunctionHandler {
    async fn invoke(
        &self,
        invocation: crate::engine::Invocation,
    ) -> Result<serde_json::Value, crate::engine::EngineError> {
        handle(&self.operation_key, &invocation, &self.deps)
            .await
            .map_err(crate::server::shared::error_mapping::capability_error_to_engine)
    }
}

pub(crate) async fn handle(
    operation_key: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = Some(invocation.payload.clone());
    match operation_key {
        "get_status" => GetStatusOperation.run(params, deps).await,
        "is_git_repo" => IsGitRepoOperation.run(params, deps).await,
        "commit" => CommitOperation.run(params, deps).await,
        "merge" => MergeOperation.run(params, deps).await,
        "list" => ListOperation.run(params, deps).await,
        "get_diff" => GetDiffOperation.run(params, deps).await,
        "acquire" => AcquireOperation.run(params, deps).await,
        "release" => ReleaseOperation.run(params, deps).await,
        "list_session_branches" => ListSessionBranchesOperation.run(params, deps).await,
        "get_committed_diff" => GetCommittedDiffOperation.run(params, deps).await,
        "delete_branch" => DeleteBranchOperation.run(params, deps).await,
        "prune_branches" => PruneBranchesOperation.run(params, deps).await,
        "stage_files" => StageFilesOperation.run(params, deps).await,
        "unstage_files" => UnstageFilesOperation.run(params, deps).await,
        "discard_files" => DiscardFilesOperation.run(params, deps).await,
        "finalize_session"
        | "rebase_on_main"
        | "start_merge"
        | "list_conflicts"
        | "resolve_conflict"
        | "continue_merge"
        | "abort_merge"
        | "resolve_conflicts_with_subagent" => {
            crate::server::domains::worktree::git_workflow::handle(operation_key, invocation, deps)
                .await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("operation {operation_key} is not worktree-owned"),
        }),
    }
}
