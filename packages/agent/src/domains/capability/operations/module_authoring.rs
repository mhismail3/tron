//! Module authoring execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn module_proposal_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let module_authoring_deps = crate::domains::module_authoring::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_authoring::service::record_module_proposal_value_at(
        &module_authoring_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Module proposal recorded.",
        "module_proposal_record",
        details,
    ))
}

pub(super) async fn module_proposal_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_authoring_deps = crate::domains::module_authoring::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_authoring::service::list_module_proposal_value(
        &module_authoring_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .get("proposals")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} module proposal(s)."),
        "module_proposal_list",
        details,
    ))
}

pub(super) async fn module_proposal_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let module_authoring_deps = crate::domains::module_authoring::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let details = crate::domains::module_authoring::service::inspect_module_proposal_value(
        &module_authoring_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected module proposal.",
        "module_proposal_inspect",
        details,
    ))
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "moduleAuthoring": details
        }),
    )
}
