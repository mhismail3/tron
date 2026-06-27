//! Module runtime execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_runtime_request(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_runtime_deps = crate::domains::module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_runtime::service::request_module_runtime_value_at(
        &module_runtime_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module runtime request recorded.",
        "module_runtime_request",
        details,
    ))
}

pub(super) async fn module_runtime_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_runtime_deps = crate::domains::module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_runtime::service::list_module_runtime_value(
        &module_runtime_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("moduleRuntimes")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module runtime record(s)."),
        "module_runtime_list",
        details,
    ))
}

pub(super) async fn module_runtime_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_runtime_deps = crate::domains::module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_runtime::service::inspect_module_runtime_value(
        &module_runtime_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected module runtime record.",
        "module_runtime_inspect",
        details,
    ))
}

pub(super) async fn module_runtime_cancel(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_runtime_deps = crate::domains::module_runtime::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_runtime::service::cancel_module_runtime_value_at(
        &module_runtime_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module runtime cancellation recorded.",
        "module_runtime_cancel",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleRuntime": details
        }),
    )
}
