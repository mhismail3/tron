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
