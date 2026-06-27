//! Module validation execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_validation_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_validation_deps = crate::domains::module_validation::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_validation::service::record_module_validation_report_value_at(
            &module_validation_deps,
            invocation,
            &invocation.payload,
            operation_at,
        )
        .await?;
    Ok(result(
        "Module validation report recorded.",
        "module_validation_record",
        details,
    ))
}

pub(super) async fn module_validation_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_validation_deps = crate::domains::module_validation::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_validation::service::list_module_validation_report_value(
        &module_validation_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("validationReports")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module validation report(s)."),
        "module_validation_list",
        details,
    ))
}

pub(super) async fn module_validation_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_validation_deps = crate::domains::module_validation::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details =
        crate::domains::module_validation::service::inspect_module_validation_report_value(
            &module_validation_deps,
            invocation,
            &invocation.payload,
        )
        .await?;
    Ok(result(
        "Inspected module validation report.",
        "module_validation_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleValidation": details
        }),
    )
}
