//! Parameter validation helpers.
//!
//! Typed extraction from [`serde_json::Value`] with user-friendly error messages
//! returned as [`TronToolResult`] (not panics or unwraps).

use serde_json::Value;
use tron_core::tools::{TronToolResult, error_result};

/// Extract a required string parameter.
///
/// Returns `Err(TronToolResult)` with `is_error=true` if the parameter is
/// missing, null, empty, or the wrong type.
pub fn validate_required_string(
    args: &Value,
    param: &str,
    description: &str,
) -> Result<String, TronToolResult> {
    match args.get(param) {
        Some(Value::String(s)) if !s.is_empty() => Ok(s.clone()),
        Some(Value::String(_) | Value::Null) | None => Err(error_result(format!(
            "Missing required parameter: {param} ({description})"
        ))),
        Some(_) => Err(error_result(format!(
            "Invalid type for parameter: {param} (expected string)"
        ))),
    }
}

/// Validate that a path is not a root/dangerous path.
///
/// Blocks `/`, `.`, and empty string.
pub fn validate_path_not_root(path: &str, param: &str) -> Result<(), TronToolResult> {
    if path.is_empty() || path == "/" || path == "." {
        return Err(error_result(format!(
            "Invalid path for {param}: \"{path}\" (must be a specific file path)"
        )));
    }
    Ok(())
}

/// Extract an optional string parameter.
pub fn get_optional_string(args: &Value, param: &str) -> Option<String> {
    args.get(param).and_then(Value::as_str).map(String::from)
}

/// Extract an optional boolean parameter.
pub fn get_optional_bool(args: &Value, param: &str) -> Option<bool> {
    args.get(param).and_then(Value::as_bool)
}

/// Extract an optional integer parameter.
pub fn get_optional_u64(args: &Value, param: &str) -> Option<u64> {
    args.get(param).and_then(Value::as_u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn validate_required_string_present_and_non_empty() {
        let args = json!({"name": "hello"});
        let result = validate_required_string(&args, "name", "the name");
        assert_eq!(result.unwrap(), "hello");
    }

    #[test]
    fn validate_required_string_missing() {
        let args = json!({});
        let result = validate_required_string(&args, "name", "the name");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.is_error, Some(true));
    }

    #[test]
    fn validate_required_string_null_value() {
        let args = json!({"name": null});
        let result = validate_required_string(&args, "name", "the name");
        assert!(result.is_err());
    }

    #[test]
    fn validate_required_string_empty() {
        let args = json!({"name": ""});
        let result = validate_required_string(&args, "name", "the name");
        assert!(result.is_err());
    }

    #[test]
    fn validate_required_string_wrong_type() {
        let args = json!({"name": 42});
        let result = validate_required_string(&args, "name", "the name");
        assert!(result.is_err());
        // Check the error message mentions "expected string"
        let err = result.unwrap_err();
        assert!(crate::testutil::extract_text(&err).contains("expected string"));
    }

    #[test]
    fn validate_path_not_root_slash() {
        assert!(validate_path_not_root("/", "file_path").is_err());
    }

    #[test]
    fn validate_path_not_root_dot() {
        assert!(validate_path_not_root(".", "file_path").is_err());
    }

    #[test]
    fn validate_path_not_root_empty() {
        assert!(validate_path_not_root("", "file_path").is_err());
    }

    #[test]
    fn validate_path_not_root_valid() {
        assert!(validate_path_not_root("/home/user/file.txt", "file_path").is_ok());
    }

    #[test]
    fn get_optional_string_present() {
        let args = json!({"key": "value"});
        assert_eq!(get_optional_string(&args, "key"), Some("value".into()));
    }

    #[test]
    fn get_optional_string_missing() {
        let args = json!({});
        assert_eq!(get_optional_string(&args, "key"), None);
    }

}
