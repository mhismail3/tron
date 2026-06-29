//! Module manifest execute operation adapter.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::domains::module_registry::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value =
        service::list_modules_value(&deps.engine_host, invocation, &invocation.payload).await?;
    let count = value
        .get("modules")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} module manifest record(s)."),
        json!({
            "primitiveOperation": "module_list",
            "status": "ok",
            "moduleRegistry": value
        }),
    ))
}

pub(super) async fn module_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value =
        service::inspect_module_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(ok_result(
        format!(
            "Inspected module manifest {}.",
            value["resource"]["resourceId"]
                .as_str()
                .unwrap_or("module_manifest")
        ),
        json!({
            "primitiveOperation": "module_inspect",
            "status": "ok",
            "moduleRegistry": value
        }),
    ))
}
