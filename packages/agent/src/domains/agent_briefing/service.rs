use serde_json::Value;

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;
use crate::shared::server::errors::CapabilityError;

use super::Deps;
use super::projection::briefing_from_module_activity;

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 40;

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "overview" => |invocation, deps| {
            overview_value(deps, invocation).await
        },
    ];
}

pub(crate) async fn overview_value(
    deps: &Deps,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIMIT)
        .clamp(1, MAX_LIMIT);
    let module_deps = crate::domains::module_activity::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let module_activity =
        crate::domains::module_activity::service::overview_value(&module_deps, invocation).await?;
    Ok(briefing_from_module_activity(
        module_activity,
        invocation,
        limit,
    ))
}
