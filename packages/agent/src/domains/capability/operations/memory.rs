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
    Ok(ok_result(
        "Memory record inspected with redacted payload.".to_owned(),
        json!({
            "primitiveOperation": "memory_inspect",
            "status": "ok",
            "memory": record
        }),
    ))
}

pub(super) async fn memory_query_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let queries =
        service::list_memory_queries_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let count = queries
        .get("queries")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Memory query evidence list returned {count} redacted records."),
        json!({
            "primitiveOperation": "memory_query_list",
            "status": "ok",
            "memory": queries
        }),
    ))
}

pub(super) async fn memory_query_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let query =
        service::inspect_memory_query_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    Ok(ok_result(
        "Memory query evidence inspected with redacted payload.".to_owned(),
        json!({
            "primitiveOperation": "memory_query_inspect",
            "status": "ok",
            "memory": query
        }),
    ))
}

pub(super) async fn memory_decision_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let decisions =
        service::list_memory_decisions_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let count = decisions
        .get("decisions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Memory decision evidence list returned {count} redacted records."),
        json!({
            "primitiveOperation": "memory_decision_list",
            "status": "ok",
            "memory": decisions
        }),
    ))
}

pub(super) async fn memory_decision_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let decision =
        service::inspect_memory_decision_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    Ok(ok_result(
        "Memory decision evidence inspected with redacted payload.".to_owned(),
        json!({
            "primitiveOperation": "memory_decision_inspect",
            "status": "ok",
            "memory": decision
        }),
    ))
}
