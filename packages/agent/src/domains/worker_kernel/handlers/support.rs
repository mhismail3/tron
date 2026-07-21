//! Shared payload admission and engine error translation.

use serde_json::Value;

use crate::engine::Invocation;
use crate::shared::server::errors::ToolError;

use super::Deps;

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

/// Read exact textual content while still rejecting absent or blank values.
/// Unified diffs require their terminal newline, so the identifier-oriented
/// `required_string` normalization must never be used for patch bytes.
pub(super) fn required_content(value: &Value, field: &str) -> Result<String, String> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|content| !content.trim().is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| format!("{field} is required"))
}

pub(super) fn require_autonomous(deps: &Deps) -> Result<(), String> {
    if deps.runtime.autonomous_enabled() {
        Ok(())
    } else {
        Err(
            "autonomous workers are disabled for this engine; set autonomousWorkers=true"
                .to_owned(),
        )
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn exact_patch_content_preserves_the_terminal_newline() {
        let patch = "diff --git a/file b/file\n-old\n+new\n";
        assert_eq!(
            required_content(&json!({"patch":patch}), "patch"),
            Ok(patch.to_owned())
        );
        assert!(required_content(&json!({"patch":"  \n"}), "patch").is_err());
    }
}
