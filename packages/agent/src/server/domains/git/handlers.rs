//! Operation binding for the git worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    _deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "git::clone" => CloneOperation.run(Some(invocation.payload.clone())).await,
        _ => Err(CapabilityError::Internal {
            message: format!("operation {method} is not git-owned"),
        }),
    }
}
