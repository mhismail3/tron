//! Subagent task execute operation adapter.

use serde_json::{Value, json};

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
    let plan = crate::domains::subagents::execution::plan_subagent_launch_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let value = match plan {
        crate::domains::subagents::execution::SubagentLaunchPlan::Replay(value) => value,
        crate::domains::subagents::execution::SubagentLaunchPlan::StartModuleProgram(
            module_payload,
        ) => {
            let module_invocation =
                invocation_with_module_start_payload(invocation, module_payload);
            let module_start = super::module_program_execution::module_program_execution_start(
                &module_invocation,
                deps,
                chrono::Utc::now(),
            )
            .await?;
            let module_details = module_program_details(&module_start, "subagent_launch")?;
            crate::domains::subagents::execution::launch_subagent_value(
                &subagent_deps,
                invocation,
                &invocation.payload,
                module_details,
            )
            .await?
        }
    };
    Ok(ok_result(
        format!(
            "Launched delegated subagent lifecycle {}.",
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
    let followup = crate::domains::subagents::execution::delegated_module_followup_payload(
        &subagent_deps,
        invocation,
        &invocation.payload,
        "subagent_status",
    )
    .await?;
    let module_invocation = invocation_with_payload(
        invocation,
        with_operation(followup, "module_program_execution_status"),
        &[
            "module_runtime.read",
            "program_execution.read",
            "jobs.read",
            "resource.read",
        ],
    );
    let module_status =
        super::module_program_execution::module_program_execution_status(&module_invocation, deps)
            .await?;
    let module_details = module_program_details(&module_status, "subagent_status")?;
    let value = crate::domains::subagents::execution::status_subagent_from_module_value(
        value,
        module_details,
    );
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
    let followup = crate::domains::subagents::execution::delegated_module_followup_payload(
        &subagent_deps,
        invocation,
        &invocation.payload,
        "subagent_result",
    )
    .await?;
    let module_invocation = invocation_with_payload(
        invocation,
        with_operation(followup, "module_program_execution_status"),
        &[
            "module_runtime.read",
            "program_execution.read",
            "jobs.read",
            "resource.read",
        ],
    );
    let module_status =
        super::module_program_execution::module_program_execution_status(&module_invocation, deps)
            .await?;
    let module_details = module_program_details(&module_status, "subagent_result")?;
    let value = crate::domains::subagents::execution::result_subagent_from_module_value(
        &subagent_deps,
        invocation,
        &invocation.payload,
        module_details,
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
    let followup = crate::domains::subagents::execution::delegated_module_followup_payload(
        &subagent_deps,
        invocation,
        &invocation.payload,
        "subagent_cancel",
    )
    .await?;
    let module_invocation = invocation_with_payload(
        invocation,
        with_operation(followup, "module_program_execution_cancel"),
        &[
            "module_runtime.read",
            "module_runtime.write",
            "program_execution.read",
            "jobs.read",
            "jobs.write",
            "resource.read",
            "resource.write",
        ],
    );
    let _module_cancel = super::module_program_execution::module_program_execution_cancel(
        &module_invocation,
        deps,
        chrono::Utc::now(),
    )
    .await?;
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

fn invocation_with_module_start_payload(invocation: &Invocation, payload: Value) -> Invocation {
    invocation_with_payload(
        invocation,
        payload,
        &[
            "module_runtime.read",
            "module_runtime.write",
            "program_execution.read",
            "program_execution.write",
            "jobs.read",
            "jobs.write",
            "resource.read",
            "resource.write",
        ],
    )
}

fn invocation_with_payload(invocation: &Invocation, payload: Value, scopes: &[&str]) -> Invocation {
    let mut delegated = invocation.clone();
    if let Some(idempotency_key) = payload.get("idempotencyKey").and_then(Value::as_str) {
        delegated.causal_context = delegated
            .causal_context
            .with_idempotency_key(idempotency_key.to_owned());
    }
    delegated.payload = payload;
    for scope in scopes {
        if !delegated.causal_context.has_scope(scope) {
            delegated.causal_context = delegated.causal_context.with_scope(*scope);
        }
    }
    delegated
}

fn with_operation(mut payload: Value, operation: &str) -> Value {
    payload["operation"] = json!(operation);
    payload
}

fn module_program_details<'a>(
    result: &'a CapabilityResult,
    operation: &str,
) -> Result<&'a Value, CapabilityError> {
    result
        .details
        .as_ref()
        .and_then(|details| details.get("moduleProgramExecution"))
        .ok_or_else(|| CapabilityError::Internal {
            message: format!("{operation} delegated module operation omitted details"),
        })
}
