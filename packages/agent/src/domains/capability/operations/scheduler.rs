use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::domains::scheduler::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) fn is_scheduler_operation(operation: &str) -> bool {
    matches!(
        operation,
        "schedule_create"
            | "schedule_list"
            | "schedule_inspect"
            | "schedule_cancel"
            | "schedule_fire_due"
    )
}

pub(super) fn requires_scheduler_idempotency(operation: &str) -> bool {
    matches!(
        operation,
        "schedule_create" | "schedule_cancel" | "schedule_fire_due"
    )
}

pub(super) async fn schedule_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::create_schedule_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Schedule recorded.", details))
}

pub(super) async fn schedule_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::list_schedules_value(&deps.engine_host, invocation, &invocation.payload).await?;
    let count = details
        .get("schedules")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Schedule list returned {count} bounded record(s)."),
        details,
    ))
}

pub(super) async fn schedule_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::inspect_schedule_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Schedule inspected.", details))
}

pub(super) async fn schedule_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::cancel_schedule_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Schedule cancelled.", details))
}

pub(super) async fn schedule_fire_due(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::fire_due_schedules_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    Ok(result("Due schedules evaluated.", details))
}

fn result(text: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": details
                .get("primitiveOperation")
                .and_then(Value::as_str)
                .unwrap_or("scheduler"),
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "scheduler": details
        }),
    )
}
