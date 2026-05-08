//! Operation binding for the message worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "message::delete" => message_delete_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("message method {method} is not engine-owned"),
        }),
    }
}
