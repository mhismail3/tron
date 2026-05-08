//! Operation binding for the model worker.

use super::operations;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
    allow_server_context: bool,
) -> Result<Value, CapabilityError> {
    match method {
        "model::list" => {
            operations::list_models(&invocation.payload, deps, allow_server_context).await
        }
        "model::switch" => operations::switch_model(&invocation.payload, deps).await,
        "config::set_reasoning_level" => {
            operations::set_reasoning_level(&invocation.payload, deps).await
        }
        _ => Err(CapabilityError::Internal {
            message: format!("model method {method} is not engine-owned"),
        }),
    }
}
