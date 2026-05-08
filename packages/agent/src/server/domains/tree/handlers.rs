//! Operation binding for the tree worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "tree::get_visualization" => get_visualization(&invocation.payload, deps).await,
        "tree::get_branches" => get_branches(&invocation.payload, deps).await,
        "tree::get_subtree" => get_subtree(&invocation.payload, deps).await,
        "tree::get_ancestors" => get_ancestors(&invocation.payload, deps).await,
        "tree::compare_branches" => compare_branches(&invocation.payload).await,
        _ => Err(CapabilityError::Internal {
            message: format!("tree method {method} is not engine-owned"),
        }),
    }
}
