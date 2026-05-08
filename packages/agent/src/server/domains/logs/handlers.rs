//! Operation binding for the logs worker.

use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "logs::ingest" => ingest_logs_value(Some(payload), deps).await,
        "logs::recent" => recent_logs_value(Some(payload.clone()), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("logs method {method} is not engine-owned"),
        }),
    }
}
