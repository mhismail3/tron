//! Operation binding for the memory worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "memory::retain" => retain_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("memory method {method} is not engine-owned"),
        }),
    }
}
