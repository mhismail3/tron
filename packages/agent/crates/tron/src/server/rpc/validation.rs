//! Input validation helpers for RPC parameters.

use super::errors::RpcError;

/// Maximum prompt length (1 MB).
pub const MAX_PROMPT_LENGTH: usize = 1_048_576;

/// Maximum general string parameter length (8 KB).
pub const MAX_PARAM_LENGTH: usize = 8_192;

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
            message: "failed at /Users/user/.tron/database/events.db: disk full".into(),
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
}
