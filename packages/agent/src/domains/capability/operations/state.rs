//! State primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, compact_json, internal, ok_result, optional_str, required_str};
use crate::engine::{CausalContext, FunctionId, Invocation};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn state_get(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let payload = state_payload(invocation, false)?;
    let value = invoke_engine_value(
        deps,
        "state::get",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State read: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_get",
            "status": "ok",
            "state": value
        }),
    ))
}

pub(super) async fn state_set(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let payload = state_payload(invocation, true)?;
    let value = invoke_engine_value(
        deps,
        "state::set",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State updated: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_set",
            "status": "ok",
            "state": value
        }),
    ))
}

pub(super) async fn state_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut payload = json!({
        "scope": optional_str(&invocation.payload, "scope")?.unwrap_or("session"),
        "namespace": required_str(&invocation.payload, "namespace")?,
    });
    if let Some(prefix) = optional_str(&invocation.payload, "keyPrefix")? {
        payload["keyPrefix"] = json!(prefix);
    }
    let value = invoke_engine_value(
        deps,
        "state::list",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State entries: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_list",
            "status": "ok",
            "state": value
        }),
    ))
}

fn state_payload(invocation: &Invocation, include_value: bool) -> Result<Value, CapabilityError> {
    let mut payload = json!({
        "scope": optional_str(&invocation.payload, "scope")?.unwrap_or("session"),
        "namespace": required_str(&invocation.payload, "namespace")?,
        "key": required_str(&invocation.payload, "key")?,
    });
    if include_value {
        payload["value"] = invocation.payload.get("value").cloned().ok_or_else(|| {
            CapabilityError::InvalidParams {
                message: "missing required field value".to_owned(),
            }
        })?;
    }
    Ok(payload)
}

async fn invoke_engine_value(
    deps: &Deps,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Result<Value, CapabilityError> {
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(|error| internal(error.to_string()))?,
            payload,
            causal_context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(internal(format!("{function_id} failed: {error}")));
    }
    result
        .value
        .ok_or_else(|| internal(format!("{function_id} returned no value")))
}
