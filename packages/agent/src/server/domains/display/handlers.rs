//! Operation binding for the display worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "display::stop_stream" => stop_stream(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("display method {method} is not engine-owned"),
        }),
    }
}
