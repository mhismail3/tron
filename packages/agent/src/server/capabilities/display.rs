use super::*;

use crate::server::capabilities::params::require_string_param;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "display::stop_stream" => stop_stream(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("display method {method} is not engine-owned"),
        }),
    }
}

async fn stop_stream(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let stream_id = require_string_param(Some(payload), "streamId")?;
    let session_id = payload
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or("");

    let stopped = if let Some(ref process_manager) = deps.process_manager {
        let label = format!("display_stream:{stream_id}");
        if let Some(process_id) = process_manager.find_by_label(session_id, &label) {
            let _ = process_manager.cancel_process(&process_id, false);
            true
        } else {
            false
        }
    } else {
        false
    };

    Ok(json!({
        "streamId": stream_id,
        "stopped": stopped,
    }))
}
