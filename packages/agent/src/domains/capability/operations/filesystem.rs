//! Filesystem primitive execute operations.

use std::path::{Component, Path, PathBuf};

use serde_json::json;

use super::{internal, ok_result, required_str};
use crate::domains::capability::Deps;
use crate::domains::filesystem::agent_tools;
use crate::engine::{Invocation, RUNTIME_METADATA_WORKING_DIRECTORY};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

const MAX_FILE_READ_BYTES: u64 = 256 * 1024;

pub(super) async fn file_read(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let path = resolve_relative_path(invocation, required_str(&invocation.payload, "path")?)?;
    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|error| internal(format!("read metadata {}: {error}", path.display())))?;
    if metadata.len() > MAX_FILE_READ_BYTES {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "file_read refuses files larger than {MAX_FILE_READ_BYTES} bytes in the primitive loop"
            ),
        });
    }
    let content = tokio::fs::read_to_string(&path)
        .await
        .map_err(|error| internal(format!("read {}: {error}", path.display())))?;
    Ok(ok_result(
        content.clone(),
        json!({
            "primitiveOperation": "file_read",
            "status": "ok",
            "path": path,
            "bytes": content.len()
        }),
    ))
}

pub(super) async fn file_write(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let path = resolve_relative_path(invocation, required_str(&invocation.payload, "path")?)?;
    let content = required_str(&invocation.payload, "content")?;
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|error| internal(format!("create {}: {error}", parent.display())))?;
    }
    tokio::fs::write(&path, content)
        .await
        .map_err(|error| internal(format!("write {}: {error}", path.display())))?;
    Ok(ok_result(
        format!("Wrote {} bytes to {}.", content.len(), path.display()),
        json!({
            "primitiveOperation": "file_write",
            "status": "ok",
            "path": path,
            "bytes": content.len()
        }),
    ))
}

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

fn resolve_relative_path(invocation: &Invocation, raw: &str) -> Result<PathBuf, CapabilityError> {
    if raw.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "path must not be empty".to_owned(),
        });
    }
    let candidate = Path::new(raw);
    if candidate.is_absolute() {
        return Err(CapabilityError::InvalidParams {
            message: "primitive file paths must be relative to the working directory".to_owned(),
        });
    }
    for component in candidate.components() {
        if matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        ) {
            return Err(CapabilityError::InvalidParams {
                message: "primitive file paths must not escape the working directory".to_owned(),
            });
        }
    }
    Ok(working_directory(invocation)?.join(candidate))
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
