//! Shared admission, path resolution, and blocking-executor support.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;

pub(super) const MAX_FILE_BYTES: usize = 4 * 1_048_576;

pub(crate) fn resolve_path(invocation: &Invocation, value: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        return Ok(path);
    }
    let base = invocation
        .causal_context
        .working_directory()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    Ok(base.join(path))
}
pub(super) fn decode_bounded_utf8(
    mut bytes: Vec<u8>,
    truncated: bool,
    path: &Path,
) -> Result<String, String> {
    match String::from_utf8(bytes) {
        Ok(content) => Ok(content),
        Err(error) if truncated && error.utf8_error().error_len().is_none() => {
            let valid = error.utf8_error().valid_up_to();
            bytes = error.into_bytes();
            bytes.truncate(valid);
            String::from_utf8(bytes).map_err(|_| format!("read {}: invalid UTF-8", path.display()))
        }
        Err(_) => Err(format!("read {}: file is not UTF-8", path.display())),
    }
}

pub(super) fn bounded_usize(payload: &Value, field: &str, default: usize, maximum: usize) -> usize {
    payload
        .get(field)
        .and_then(Value::as_u64)
        .unwrap_or(default as u64)
        .clamp(1, maximum as u64) as usize
}

pub(super) fn required_string(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{field} is required"))
}

pub(super) async fn run_blocking<F>(operation: &'static str, task: F) -> Result<Value, String>
where
    F: FnOnce() -> Result<Value, String> + Send + 'static,
{
    run_blocking_task(operation, move || {
        task().map_err(|message| ToolError::Internal { message })
    })
    .await
    .map_err(|error| error.to_string())
}
