//! Git primitive execute operations.

use serde_json::json;

use super::{Deps, ok_result};
use crate::domains::git::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn git_status(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = service::status_value(invocation, &invocation.payload).await?;
    git_result("git_status", result)
}

pub(super) async fn git_diff(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let result = service::diff_value(invocation, &invocation.payload).await?;
    git_result("git_diff", result)
}

pub(super) async fn git_branch_inventory(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::branch_inventory::branch_inventory_value(
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_branch_inventory", result)
}

pub(super) async fn git_stage(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::mutation::stage_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_stage", result)
}

pub(super) async fn git_unstage(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::mutation::unstage_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_unstage", result)
}

pub(super) async fn git_commit(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::commit::commit_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_commit", result)
}

pub(super) async fn git_branch_start(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result = crate::domains::git::branch_start::branch_start_value(
        &deps.engine_host,
        invocation,
        &invocation.payload,
    )
    .await?;
    git_result("git_branch_start", result)
}

fn git_result(
    operation: &'static str,
    result: serde_json::Value,
) -> Result<CapabilityResult, CapabilityError> {
    let status = result["status"].as_str().unwrap_or("ok");
    let path = result
        .pointer("/path/relativePath")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(".");
    Ok(ok_result(
        format!("{operation} {status}: {path}"),
        json!({
            "primitiveOperation": operation,
            "status": status,
            "git": result
        }),
    ))
}
