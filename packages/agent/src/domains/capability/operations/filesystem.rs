//! Filesystem primitive execute operations.
//!
//! Legacy `file_read`/`file_write` operation names are intentionally absent
//! from this module. Model-visible file access must go through the hardened
//! `filesystem_*` package wrappers below.

use std::path::PathBuf;

use serde_json::json;

use super::{internal, ok_result};
use crate::domains::capability::Deps;
use crate::domains::filesystem::agent_tools;
use crate::engine::{Invocation, RUNTIME_METADATA_WORKING_DIRECTORY};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn filesystem_read(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::read_value(invocation, &invocation.payload).await?;
    filesystem_result("filesystem_read", result)
}

pub(super) async fn filesystem_list(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::list_value(invocation, &invocation.payload).await?;
    filesystem_result("filesystem_list", result)
}

pub(super) async fn filesystem_find(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::find_value(invocation, &invocation.payload, false).await?;
    filesystem_result("filesystem_find", result)
}

pub(super) async fn filesystem_glob(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::find_value(invocation, &invocation.payload, true).await?;
    filesystem_result("filesystem_glob", result)
}

pub(super) async fn filesystem_search_text(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::search_text_value(invocation, &invocation.payload).await?;
    filesystem_result("filesystem_search_text", result)
}

pub(super) async fn filesystem_diff(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let result = agent_tools::diff_value(invocation, &invocation.payload).await?;
    filesystem_result("filesystem_diff", result)
}

pub(super) async fn filesystem_write(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        agent_tools::write_value(&deps.engine_host, invocation, &invocation.payload).await?;
    filesystem_result("filesystem_write", result)
}

pub(super) async fn filesystem_edit(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        agent_tools::edit_value(&deps.engine_host, invocation, &invocation.payload).await?;
    filesystem_result("filesystem_edit", result)
}

pub(super) async fn filesystem_apply_patch(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let result =
        agent_tools::edit_value(&deps.engine_host, invocation, &invocation.payload).await?;
    filesystem_result("filesystem_apply_patch", result)
}

fn filesystem_result(
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
            "filesystem": result
        }),
    ))
}

pub(super) fn working_directory(invocation: &Invocation) -> Result<PathBuf, CapabilityError> {
    let raw = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "capability::execute requires trusted working directory metadata".to_owned(),
        })?;
    crate::shared::foundation::paths::normalize_working_directory(raw).map_err(internal)
}
