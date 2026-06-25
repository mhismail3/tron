use serde_json::{Value, json};

use super::ok_result;
use crate::domains::capability::Deps;
use crate::domains::procedural::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn procedural_state_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let records =
        service::list_procedural_state_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let count = records
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Procedural state list returned {count} redacted records."),
        json!({
            "primitiveOperation": "procedural_state_list",
            "status": "ok",
            "procedural": records
        }),
    ))
}

pub(super) async fn procedural_state_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let record =
        service::inspect_procedural_state_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let resource_id = record["resource"]["resourceId"]
        .as_str()
        .unwrap_or("unknown");
    Ok(ok_result(
        format!("Procedural record inspected with redacted payload: {resource_id}."),
        json!({
            "primitiveOperation": "procedural_state_inspect",
            "status": "ok",
            "procedural": record
        }),
    ))
}
