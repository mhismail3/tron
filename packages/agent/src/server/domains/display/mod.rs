//! display domain worker.
//!
//! This module owns canonical function execution for the display namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        super::domain_worker_module(
            "display",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

use crate::server::shared::params::require_string_param;

async fn stop_stream(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
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
