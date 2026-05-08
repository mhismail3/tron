//! Operation binding for the repo worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "repo::list_sessions" => list_sessions(&invocation.payload, deps).await,
        "repo::get_divergence" => get_divergence(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("repo method {method} is not engine-owned"),
        }),
    }
}
