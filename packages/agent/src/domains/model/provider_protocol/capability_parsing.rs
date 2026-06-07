//! # ModelCapability Call Argument Parsing
//!
//! Safe JSON parsing for capability invocation arguments received from LLM providers.
//! Completed provider invocations must carry either absent/empty arguments or a
//! JSON object. Malformed or non-object arguments fail closed before they enter
//! canonical capability state.

use std::fmt;

use serde_json::{Map, Value};

/// Context for logging when capability invocation parsing fails.
#[derive(Clone, Debug, Default)]
pub struct CapabilityCallContext {
    /// The capability invocation ID (for correlation).
    pub invocation_id: Option<String>,
    /// The capability id.
    pub model_primitive_name: Option<String>,
    /// The provider that generated this capability invocation.
    pub provider: Option<String>,
}

/// Parse failure for provider-emitted capability invocation arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CapabilityArgumentParseError {
    message: String,
}

impl CapabilityArgumentParseError {
    fn malformed_json(context: Option<&CapabilityCallContext>, error: &serde_json::Error) -> Self {
        Self {
            message: format!(
                "{} must be a JSON object; malformed JSON at line {}, column {}: {error}",
                context_label(context),
                error.line(),
                error.column()
            ),
        }
    }

    fn non_object(context: Option<&CapabilityCallContext>, value: &Value) -> Self {
        Self {
            message: format!(
                "{} must be a JSON object; received {}",
                context_label(context),
                json_type_name(value)
            ),
        }
    }
}

impl fmt::Display for CapabilityArgumentParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CapabilityArgumentParseError {}

/// Parse capability invocation arguments JSON string into a `Map`.
///
/// Absent and empty strings are valid empty arguments. Non-empty malformed JSON
/// or non-object JSON is rejected because dispatching it as `{}` can turn a
/// provider protocol fault into a misleading capability invocation.
///
/// # Arguments
/// * `args` - Raw JSON string from the provider (may be empty, null, or malformed)
/// * `context` - Optional context for warning logs on parse failure
pub fn parse_capability_call_arguments(
    args: Option<&str>,
    context: Option<&CapabilityCallContext>,
) -> Result<Map<String, Value>, CapabilityArgumentParseError> {
    let Some(args) = args else {
        return Ok(Map::new());
    };

    let trimmed = args.trim();
    if trimmed.is_empty() {
        return Ok(Map::new());
    }

    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(other) => Err(CapabilityArgumentParseError::non_object(context, &other)),
        Err(e) => Err(CapabilityArgumentParseError::malformed_json(context, &e)),
    }
}

/// Validate that a string is valid capability invocation arguments JSON.
///
/// Returns `true` if the string is valid JSON that parses to an object,
/// or if the string is empty/null (treated as valid empty args).
pub fn is_valid_capability_call_arguments(args: Option<&str>) -> bool {
    let Some(args) = args else {
        return true;
    };

    let trimmed = args.trim();
    if trimmed.is_empty() {
        return true;
    }

    parse_capability_call_arguments(Some(trimmed), None).is_ok()
}

fn context_label(context: Option<&CapabilityCallContext>) -> String {
    let Some(context) = context else {
        return "provider capability invocation arguments".into();
    };

    let provider = context.provider.as_deref().unwrap_or("provider");
    let model_primitive_name = context
        .model_primitive_name
        .as_deref()
        .unwrap_or("unknown capability");

    match context.invocation_id.as_deref() {
        Some(invocation_id) => format!(
            "{provider} capability invocation arguments for {model_primitive_name} ({invocation_id})"
        ),
        None => {
            format!("{provider} capability invocation arguments for {model_primitive_name}")
        }
    }
}

fn json_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_json_object() {
        let result = parse_capability_call_arguments(Some(r#"{"file": "test.rs"}"#), None)
            .expect("valid object parses");
        assert_eq!(result.len(), 1);
        assert_eq!(result["file"], "test.rs");
    }

    #[test]
    fn parse_empty_object() {
        let result =
            parse_capability_call_arguments(Some("{}"), None).expect("empty object parses");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_none_returns_empty() {
        let result = parse_capability_call_arguments(None, None).expect("none is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_string_returns_empty() {
        let result = parse_capability_call_arguments(Some(""), None).expect("empty is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_whitespace_returns_empty() {
        let result = parse_capability_call_arguments(Some("  \n  "), None)
            .expect("whitespace is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_invalid_json_fails_closed() {
        let err = parse_capability_call_arguments(Some("not json"), None)
            .expect_err("malformed arguments fail closed");
        assert!(err.to_string().contains("malformed JSON"));
        assert!(
            err.to_string()
                .contains("provider capability invocation arguments")
        );
    }

    #[test]
    fn parse_non_object_json_fails_closed() {
        let err = parse_capability_call_arguments(Some("[1,2,3]"), None)
            .expect_err("non-object arguments fail closed");
        assert!(err.to_string().contains("received array"));
    }

    #[test]
    fn parse_string_json_fails_closed() {
        let err = parse_capability_call_arguments(Some("\"just a string\""), None)
            .expect_err("string arguments fail closed");
        assert!(err.to_string().contains("received string"));
    }

    #[test]
    fn parse_complex_object() {
        let args = r#"{"command": "ls -la", "timeout": 5000, "cwd": "/home"}"#;
        let result =
            parse_capability_call_arguments(Some(args), None).expect("complex object parses");
        assert_eq!(result.len(), 3);
        assert_eq!(result["command"], "ls -la");
        assert_eq!(result["timeout"], 5000);
    }

    #[test]
    fn parse_with_context_logs() {
        let ctx = CapabilityCallContext {
            invocation_id: Some("toolu_123".into()),
            model_primitive_name: Some("execute".into()),
            provider: Some("anthropic".into()),
        };
        let err = parse_capability_call_arguments(Some("broken{"), Some(&ctx))
            .expect_err("invalid JSON with context fails closed");
        let err = err.to_string();
        assert!(err.contains("anthropic capability invocation arguments"));
        assert!(err.contains("execute"));
        assert!(err.contains("toolu_123"));
    }

    #[test]
    fn parse_nested_objects() {
        let args = r#"{"outer": {"inner": "value"}}"#;
        let result =
            parse_capability_call_arguments(Some(args), None).expect("nested object parses");
        assert_eq!(result.len(), 1);
        assert!(result["outer"].is_object());
    }

    #[test]
    fn validate_valid_object() {
        assert!(is_valid_capability_call_arguments(Some(r#"{"a": 1}"#)));
    }

    #[test]
    fn validate_empty_is_valid() {
        assert!(is_valid_capability_call_arguments(None));
        assert!(is_valid_capability_call_arguments(Some("")));
    }

    #[test]
    fn validate_non_object_is_invalid() {
        assert!(!is_valid_capability_call_arguments(Some("[1,2]")));
        assert!(!is_valid_capability_call_arguments(Some("\"string\"")));
    }

    #[test]
    fn validate_invalid_json_is_invalid() {
        assert!(!is_valid_capability_call_arguments(Some("not json")));
    }
}
