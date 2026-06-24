use serde_json::Value;

use super::{Deps, ok_result};
use crate::domains::goals::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn goal_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::create_goal_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Goal recorded.", details))
}

pub(super) async fn goal_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::list_goals_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Goal list returned.", details))
}

pub(super) async fn goal_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::inspect_goal_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Goal inspected.", details))
}

pub(super) async fn goal_cancel(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::cancel_goal_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Goal cancelled.", details))
}

pub(super) async fn question_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::create_question_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Question recorded.", details))
}

pub(super) async fn question_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::list_questions_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Question list returned.", details))
}

pub(super) async fn question_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::inspect_question_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Question inspected.", details))
}

pub(super) async fn question_answer(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let details =
        service::answer_question_value(&deps.engine_host, invocation, &invocation.payload).await?;
    Ok(result("Question answered.", details))
}

fn result(text: &str, details: Value) -> CapabilityResult {
    ok_result(text.to_owned(), details)
}
