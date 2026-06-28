use serde_json::{Value, json};

use super::ok_result;
use crate::domains::capability::Deps;
use crate::domains::procedural::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;
use chrono::{DateTime, Utc};

pub(super) async fn procedural_definition_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::record_procedural_definition_value_at(
        &deps.engine_host,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(ok_result(
        "Procedural definition metadata recorded.".to_owned(),
        json!({
            "primitiveOperation": "procedural_definition_record",
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "procedural": details
        }),
    ))
}

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

pub(super) async fn procedural_activation_request_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::record_activation_request_value_at(
        &deps.engine_host,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(ok_result(
        "Procedural activation request recorded for review.".to_owned(),
        json!({
            "primitiveOperation": "procedural_activation_request_record",
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "procedural": details
        }),
    ))
}

pub(super) async fn procedural_activation_request_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::list_activation_requests_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let count = details
        .get("activationRequests")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} procedural activation request(s)."),
        json!({
            "primitiveOperation": "procedural_activation_request_list",
            "status": "ok",
            "procedural": details
        }),
    ))
}

pub(super) async fn procedural_activation_request_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::inspect_activation_request_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        "Procedural activation request inspected with redacted payload.".to_owned(),
        json!({
            "primitiveOperation": "procedural_activation_request_inspect",
            "status": "ok",
            "procedural": details
        }),
    ))
}

pub(super) async fn procedural_activation_decision_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::record_activation_decision_value_at(
        &deps.engine_host,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(ok_result(
        "Procedural activation decision recorded as metadata.".to_owned(),
        json!({
            "primitiveOperation": "procedural_activation_decision_record",
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "procedural": details
        }),
    ))
}

pub(super) async fn procedural_activation_decision_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::list_activation_decisions_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("activationDecisions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} procedural activation decision(s)."),
        json!({
            "primitiveOperation": "procedural_activation_decision_list",
            "status": "ok",
            "procedural": details
        }),
    ))
}

pub(super) async fn procedural_activation_decision_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details = service::inspect_activation_decision_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        "Procedural activation decision inspected with redacted payload.".to_owned(),
        json!({
            "primitiveOperation": "procedural_activation_decision_inspect",
            "status": "ok",
            "procedural": details
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
