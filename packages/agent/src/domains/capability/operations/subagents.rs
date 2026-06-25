//! Subagent task execute operation adapter.

use serde_json::json;

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn subagent_task_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::service::list_subagent_tasks_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = value["tasks"].as_array().map_or(0, Vec::len);
    Ok(ok_result(
        format!("Listed {count} subagent task(s)."),
        json!({
            "primitiveOperation": "subagent_task_list",
            "status": "ok",
            "subagentTasks": value
        }),
    ))
}

pub(super) async fn subagent_task_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::service::inspect_subagent_task_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Inspected subagent task {}.",
            value["task"]["resourceId"]
                .as_str()
                .unwrap_or("subagent_task")
        ),
        json!({
            "primitiveOperation": "subagent_task_inspect",
            "status": "ok",
            "subagentTasks": value
        }),
    ))
}
