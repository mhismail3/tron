//! Update diagnostics execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn update_diagnostic_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let update_diagnostics_deps = crate::domains::update_diagnostics::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::update_diagnostics::service::record_update_diagnostic_value_at(
        &update_diagnostics_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Update diagnostic metadata recorded.",
        "update_diagnostic_record",
        details,
    ))
}

pub(super) async fn update_diagnostic_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let update_diagnostics_deps = crate::domains::update_diagnostics::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::update_diagnostics::service::list_update_diagnostics_value(
        &update_diagnostics_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} update diagnostic record(s)."),
        "update_diagnostic_list",
        details,
    ))
}

pub(super) async fn update_diagnostic_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let update_diagnostics_deps = crate::domains::update_diagnostics::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::update_diagnostics::service::inspect_update_diagnostics_value(
        &update_diagnostics_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected update diagnostic metadata record.",
        "update_diagnostic_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "updateDiagnostics": details
        }),
    )
}
