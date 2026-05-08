//! Operation binding for the device worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "device::register" => register_token(&invocation.payload, deps).await,
        "device::unregister" => unregister_token(&invocation.payload, deps).await,
        "device::respond" => respond(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("device method {method} is not engine-owned"),
        }),
    }
}
