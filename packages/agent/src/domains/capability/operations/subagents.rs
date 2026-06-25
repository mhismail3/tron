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

pub(super) async fn subagent_launch(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::execution::launch_subagent_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Launched subagent lifecycle {}.",
            value["subagentTaskResourceId"]
                .as_str()
                .unwrap_or("subagent_task")
        ),
        json!({
            "primitiveOperation": "subagent_launch",
            "status": value["status"],
            "subagentTasks": value
        }),
    ))
}

pub(super) async fn subagent_status(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::execution::status_subagent_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Subagent status {}.",
            value["status"].as_str().unwrap_or("unknown")
        ),
        json!({
            "primitiveOperation": "subagent_status",
            "status": value["status"],
            "subagentTasks": value
        }),
    ))
}

pub(super) async fn subagent_result(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::execution::result_subagent_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Subagent result status {}.",
            value["status"].as_str().unwrap_or("unknown")
        ),
        json!({
            "primitiveOperation": "subagent_result",
            "status": value["status"],
            "subagentTasks": value
        }),
    ))
}

pub(super) async fn subagent_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let subagent_deps = crate::domains::subagents::Deps {
        engine_host: deps.engine_host.clone(),
    };
    let value = crate::domains::subagents::execution::cancel_subagent_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(ok_result(
        format!(
            "Subagent cancel status {}.",
            value["status"].as_str().unwrap_or("unknown")
        ),
        json!({
            "primitiveOperation": "subagent_cancel",
            "status": value["status"],
            "subagentTasks": value
        }),
    ))
}
