//! Operation binding for the voice_notes worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "voice_notes::list" => list(&invocation.payload, deps).await,
        "voice_notes::save" => save(&invocation.payload, deps).await,
        "voice_notes::delete" => delete(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("voice notes method {method} is not engine-owned"),
        }),
    }
}
