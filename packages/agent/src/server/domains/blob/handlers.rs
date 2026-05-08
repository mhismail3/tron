//! Operation binding for the blob worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "blob::get" => blob_get_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("blob method {method} is not engine-owned"),
        }),
    }
}
