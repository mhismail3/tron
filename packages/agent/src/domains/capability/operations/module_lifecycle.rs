//! Module lifecycle execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_lifecycle_request(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_lifecycle_deps = crate::domains::module_lifecycle::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_lifecycle::service::request_module_lifecycle_value_at(
        &module_lifecycle_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module lifecycle request recorded.",
        "module_lifecycle_request",
        details,
    ))
}

pub(super) async fn module_lifecycle_decision(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_lifecycle_deps = crate::domains::module_lifecycle::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_lifecycle::service::decide_module_lifecycle_value_at(
        &module_lifecycle_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module lifecycle decision recorded.",
        "module_lifecycle_decision",
        details,
    ))
}

pub(super) async fn module_lifecycle_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_lifecycle_deps = crate::domains::module_lifecycle::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_lifecycle::service::list_module_lifecycle_value(
        &module_lifecycle_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("moduleLifecycles")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module lifecycle record(s)."),
        "module_lifecycle_list",
        details,
    ))
}

pub(super) async fn module_lifecycle_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_lifecycle_deps = crate::domains::module_lifecycle::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_lifecycle::service::inspect_module_lifecycle_value(
        &module_lifecycle_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected module lifecycle record.",
        "module_lifecycle_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleLifecycle": details
        }),
    )
}
