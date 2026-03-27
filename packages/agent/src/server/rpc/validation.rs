//! Input validation helpers for RPC parameters.

use super::errors::RpcError;

/// Maximum prompt length (1 MB).
pub const MAX_PROMPT_LENGTH: usize = 1_048_576;

/// Maximum general string parameter length (8 KB).
pub const MAX_PARAM_LENGTH: usize = 8_192;

/// Maximum JSON nesting depth for incoming RPC payloads.
pub const MAX_JSON_DEPTH: usize = 128;

/// Validate that a string parameter does not exceed `max_len` bytes.
pub fn validate_string_param(value: &str, name: &str, max_len: usize) -> Result<(), RpcError> {
    if value.len() > max_len {
        return Err(RpcError::InvalidParams {
            message: format!(
                "Parameter '{name}' exceeds maximum length ({} > {max_len})",
                value.len()
            ),
        });
    }
    Ok(())
}

/// Validate that parsed JSON does not exceed the maximum nesting depth.
///
/// Uses `serde_json`'s default recursion limit of 128 as a safety net,
/// but this function provides explicit validation with a clear error message.
pub fn validate_json_depth(value: &serde_json::Value, max_depth: usize) -> Result<(), RpcError> {
    fn measure_depth(v: &serde_json::Value, current: usize, max: usize) -> Result<(), ()> {
        if current > max {
            return Err(());
        }
        match v {
            serde_json::Value::Object(map) => {
                for val in map.values() {
                    measure_depth(val, current + 1, max)?;
                }
            }
            serde_json::Value::Array(arr) => {
                for val in arr {
                    measure_depth(val, current + 1, max)?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    measure_depth(value, 0, max_depth).map_err(|()| RpcError::InvalidParams {
        message: format!("JSON nesting depth exceeds maximum of {max_depth}"),
    })
}

/// Sanitize an error message for client consumption.
///
/// Preserves user-facing messages (invalid params, not found) but strips
/// internal details (file paths, stack traces) from internal errors.
pub fn sanitize_error_message(err: &RpcError) -> String {
    match err {
        RpcError::InvalidParams { message }
        | RpcError::NotFound { message, .. }
        | RpcError::NotAvailable { message }
        | RpcError::Custom { message, .. } => message.clone(),
        RpcError::Internal { .. } => "Internal error".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_normal_param_succeeds() {
        assert!(validate_string_param("hello", "name", MAX_PARAM_LENGTH).is_ok());
    }

    #[test]
    fn validate_at_limit_succeeds() {
        let s = "x".repeat(MAX_PARAM_LENGTH);
        assert!(validate_string_param(&s, "param", MAX_PARAM_LENGTH).is_ok());
    }

    #[test]
    fn validate_oversized_param_fails() {
        let s = "x".repeat(MAX_PARAM_LENGTH + 1);
        let result = validate_string_param(&s, "myParam", MAX_PARAM_LENGTH);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
        assert!(err.to_string().contains("myParam"));
    }

    #[test]
    fn validate_normal_prompt_succeeds() {
        let prompt = "Write me a poem about Rust.";
        assert!(validate_string_param(prompt, "prompt", MAX_PROMPT_LENGTH).is_ok());
    }

    #[test]
    fn reject_oversized_prompt() {
        let prompt = "x".repeat(MAX_PROMPT_LENGTH + 1);
        let result = validate_string_param(&prompt, "prompt", MAX_PROMPT_LENGTH);
        assert!(result.is_err());
    }

    #[test]
    fn sanitize_internal_error_strips_details() {
        let err = RpcError::Internal {
            message: "failed at /Users/user/.tron/system/db/events.db: disk full".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert_eq!(sanitized, "Internal error");
        assert!(!sanitized.contains("/Users"));
    }

    #[test]
    fn sanitize_invalid_params_preserves_message() {
        let err = RpcError::InvalidParams {
            message: "Missing required parameter 'sessionId'".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert!(sanitized.contains("sessionId"));
    }

    #[test]
    fn sanitize_not_found_preserves_message() {
        let err = RpcError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: "Session 'abc' not found".into(),
        };
        let sanitized = sanitize_error_message(&err);
        assert!(sanitized.contains("abc"));
    }

    // ── JSON depth validation tests ─────────────────────────────

    fn nested_object(depth: usize) -> serde_json::Value {
        let mut v = serde_json::json!({"leaf": true});
        for _ in 0..depth {
            v = serde_json::json!({"nested": v});
        }
        v
    }

    fn nested_array(depth: usize) -> serde_json::Value {
        let mut v = serde_json::json!(42);
        for _ in 0..depth {
            v = serde_json::json!([v]);
        }
        v
    }

    #[test]
    fn depth_1_passes() {
        let v = serde_json::json!({"key": "value"});
        assert!(validate_json_depth(&v, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_10_passes() {
        assert!(validate_json_depth(&nested_object(10), MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_64_passes() {
        assert!(validate_json_depth(&nested_object(64), MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn depth_128_rejected() {
        let deep = nested_object(130);
        assert!(validate_json_depth(&deep, MAX_JSON_DEPTH).is_err());
    }

    #[test]
    fn depth_200_rejected() {
        let deep = nested_object(200);
        let result = validate_json_depth(&deep, MAX_JSON_DEPTH);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("128"));
    }

    #[test]
    fn deep_arrays_caught() {
        let deep = nested_array(150);
        assert!(validate_json_depth(&deep, MAX_JSON_DEPTH).is_err());
    }

    #[test]
    fn flat_many_keys_passes() {
        let mut map = serde_json::Map::new();
        for i in 0..1000 {
            map.insert(format!("key_{i}"), serde_json::json!(i));
        }
        let v = serde_json::Value::Object(map);
        assert!(validate_json_depth(&v, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn null_passes() {
        assert!(validate_json_depth(&serde_json::Value::Null, MAX_JSON_DEPTH).is_ok());
    }

    #[test]
    fn primitives_pass() {
        assert!(validate_json_depth(&serde_json::json!(42), MAX_JSON_DEPTH).is_ok());
        assert!(validate_json_depth(&serde_json::json!("hello"), MAX_JSON_DEPTH).is_ok());
        assert!(validate_json_depth(&serde_json::json!(true), MAX_JSON_DEPTH).is_ok());
    }
}
