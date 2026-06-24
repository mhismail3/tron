//! Goal/question primitive execute operations.

use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::domains::goals;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn goal_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "goal_create",
        goals::service::goal_create_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn goal_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "goal_list",
        goals::service::goal_list_value(&deps.engine_host, invocation, &invocation.payload).await?,
    )
}

pub(super) async fn goal_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "goal_inspect",
        goals::service::goal_inspect_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn goal_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "goal_cancel",
        goals::service::goal_cancel_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn question_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "question_create",
        goals::service::question_create_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn question_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "question_list",
        goals::service::question_list_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn question_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "question_inspect",
        goals::service::question_inspect_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

pub(super) async fn question_answer(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    goal_result(
        "question_answer",
        goals::service::question_answer_value(&deps.engine_host, invocation, &invocation.payload)
            .await?,
    )
}

fn goal_result(
    operation: &'static str,
    result: Value,
) -> Result<CapabilityResult, CapabilityError> {
    let status = result["status"].as_str().unwrap_or("ok");
    let text = match operation {
        "goal_list" => format!(
            "{operation} {status}: {} goal(s){}",
            result["goals"].as_array().map_or(0, Vec::len),
            if result["truncated"].as_bool().unwrap_or(false) {
                " (truncated)"
            } else {
                ""
            }
        ),
        "question_list" => format!(
            "{operation} {status}: {} question(s){}",
            result["questions"].as_array().map_or(0, Vec::len),
            if result["truncated"].as_bool().unwrap_or(false) {
                " (truncated)"
            } else {
                ""
            }
        ),
        _ => format!(
            "{operation} {status}: {}",
            result
                .pointer("/goal/goalResourceId")
                .or_else(|| result.pointer("/goal/summary/goalResourceId"))
                .or_else(|| result.pointer("/question/questionResourceId"))
                .or_else(|| result.pointer("/question/summary/questionResourceId"))
                .or_else(|| result.pointer("/answer/answerResourceId"))
                .and_then(Value::as_str)
                .unwrap_or("ok")
        ),
    };
    Ok(ok_result(
        text,
        json!({
            "primitiveOperation": operation,
            "status": status,
            "goals": result
        }),
    ))
}
