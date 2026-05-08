//! Operation binding for the browser worker.

use super::*;

pub(crate) async fn handle(method: &str, _deps: &Deps) -> Result<Value, CapabilityError> {
    match method {
        "browser::get_status" => Ok(json!({
            "hasBrowser": false,
            "isStreaming": false,
        })),
        _ => Err(CapabilityError::Internal {
            message: format!("browser method {method} is not engine-owned"),
        }),
    }
}
