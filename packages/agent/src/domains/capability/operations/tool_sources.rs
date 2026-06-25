//! Tool-source execute operation adapter.

use serde_json::json;

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn tool_source_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let tool_deps = crate::domains::tool_sources::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::tool_sources::service::list_tool_sources_value(
        &tool_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = value["proposals"].as_array().map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} tool source proposal(s)."),
        json!({
            "primitiveOperation": "tool_source_list",
            "status": "ok",
            "toolSources": value
        }),
    ))
}

pub(super) async fn tool_source_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let tool_deps = crate::domains::tool_sources::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::tool_sources::service::inspect_tool_source_value(
        &tool_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Inspected tool source {}.",
            value["resource"]["resourceId"]
                .as_str()
                .unwrap_or("tool_source")
        ),
        json!({
            "primitiveOperation": "tool_source_inspect",
            "status": "ok",
            "toolSources": value
        }),
    ))
}
