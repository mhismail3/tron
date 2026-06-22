use serde_json::{Value, json};

use super::ok_result;
use crate::domains::capability::Deps;
use crate::domains::memory::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn memory_status(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let status =
        service::status_memory_value(&deps.engine_host, invocation, &invocation.payload).await?;
    let mode = status["mode"].as_str().unwrap_or("unknown");
    Ok(ok_result(
        format!("Memory mode is {mode}; private memory content included in prompt: no."),
        json!({
            "primitiveOperation": "memory_status",
            "status": "ok",
            "memory": status
        }),
    ))
}

pub(super) async fn memory_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let records =
        service::list_memory_value(&deps.engine_host, invocation, &invocation.payload).await?;
    let count = records
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Memory list returned {count} redacted records."),
        json!({
            "primitiveOperation": "memory_list",
            "status": "ok",
            "memory": records
        }),
    ))
}

pub(super) async fn memory_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let record =
        service::inspect_memory_value(&deps.engine_host, invocation, &invocation.payload).await?;
    let resource_id = record["resource"]["resourceId"]
        .as_str()
        .unwrap_or("unknown");
    Ok(ok_result(
        format!("Memory record inspected with redacted payload: {resource_id}."),
        json!({
            "primitiveOperation": "memory_inspect",
            "status": "ok",
            "memory": record
        }),
    ))
}
