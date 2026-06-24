//! Read-only Git primitive execute operations.

use serde_json::json;

use super::ok_result;
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
