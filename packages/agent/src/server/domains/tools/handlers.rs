//! Operation binding for the tools worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "tool::result" => tool_result_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("tool method {method} is not engine-owned"),
        }),
    }
}
