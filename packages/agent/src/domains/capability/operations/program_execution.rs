//! Program execution execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn program_execution_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let program_execution_deps = crate::domains::program_execution::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::program_execution::service::record_program_execution_record_value_at(
            &program_execution_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Program execution recorded.",
        "program_execution_record",
        details,
    ))
}

pub(super) async fn program_execution_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let program_execution_deps = crate::domains::program_execution::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::program_execution::service::list_program_execution_value(
        &program_execution_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} program execution(s)."),
        "program_execution_list",
        details,
    ))
}

pub(super) async fn program_execution_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let program_execution_deps = crate::domains::program_execution::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::program_execution::service::inspect_program_execution_value(
        &program_execution_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected program execution.",
        "program_execution_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "programExecution": details
        }),
    )
}
