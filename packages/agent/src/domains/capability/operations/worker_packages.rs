//! Worker package lifecycle inspection adapters.

use serde_json::json;

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn worker_package_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = crate::domains::worker_lifecycle::inspection::list_worker_packages_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = value["records"].as_array().map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} worker lifecycle package record(s)."),
        json!({
            "primitiveOperation": "worker_package_list",
            "status": "ok",
            "workerPackages": value
        }),
    ))
}

pub(super) async fn worker_package_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let value = crate::domains::worker_lifecycle::inspection::inspect_worker_package_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Inspected worker lifecycle resource {}.",
            value["resource"]["resourceId"]
                .as_str()
                .unwrap_or("worker_package")
        ),
        json!({
            "primitiveOperation": "worker_package_inspect",
            "status": "ok",
            "workerPackages": value
        }),
    ))
}
