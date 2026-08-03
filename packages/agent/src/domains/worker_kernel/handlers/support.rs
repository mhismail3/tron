//! Shared payload admission and engine error translation.

use serde_json::Value;

use crate::engine::Invocation;
use crate::shared::server::errors::ToolError;

pub(super) fn response(
    invocation: &Invocation,
    result: Result<Value, String>,
) -> Result<Value, ToolError> {
    let _ = invocation;
    result.map_err(|message| ToolError::Internal { message })
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
