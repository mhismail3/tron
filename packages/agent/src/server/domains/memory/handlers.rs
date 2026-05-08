//! Operation binding for the memory worker.

use super::operations;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "memory::retain" => operations::retain(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}
