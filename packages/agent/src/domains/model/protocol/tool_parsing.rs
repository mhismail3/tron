//! # ModelTool Call Argument Parsing
//!
//! Safe JSON parsing for tool invocation arguments received from LLM providers.
//! Completed provider invocations must carry either absent/empty arguments or a
//! JSON object. Malformed or non-object arguments fail closed before they enter
//! canonical tool state.

use std::fmt;

use serde_json::{Map, Value};

/// Context for logging when tool invocation parsing fails.
#[derive(Clone, Debug, Default)]
pub struct ToolCallContext {
    /// The tool invocation ID (for correlation).
    pub invocation_id: Option<String>,
    /// The tool id.
    pub tool_name: Option<String>,
    /// The provider that generated this tool invocation.
    pub provider: Option<String>,
}

/// Parse failure for provider-emitted tool invocation arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolArgumentParseError {
    message: String,
}

impl ToolArgumentParseError {
    fn malformed_json(context: Option<&ToolCallContext>, error: &serde_json::Error) -> Self {
        Self {
            message: format!(
                "{} must be a JSON object; malformed JSON at line {}, column {}: {error}",
                context_label(context),
                error.line(),
                error.column()
            ),
        }
    }

    fn non_object(context: Option<&ToolCallContext>, value: &Value) -> Self {
        Self {
            message: format!(
                "{} must be a JSON object; received {}",
                context_label(context),
                json_type_name(value)
            ),
        }
    }
}

impl fmt::Display for ToolArgumentParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ToolArgumentParseError {}

/// Parse tool invocation arguments JSON string into a `Map`.
///
/// Absent and empty strings are valid empty arguments. Non-empty malformed JSON
/// or non-object JSON is rejected because dispatching it as `{}` can turn a
/// provider protocol fault into a misleading tool invocation.
///
/// # Arguments
/// * `args` - Raw JSON string from the provider (may be empty, null, or malformed)
/// * `context` - Optional context for warning logs on parse failure
pub fn parse_tool_call_arguments(
    args: Option<&str>,
    context: Option<&ToolCallContext>,
) -> Result<Map<String, Value>, ToolArgumentParseError> {
    let Some(args) = args else {
        return Ok(Map::new());
    };

    let trimmed = args.trim();
    if trimmed.is_empty() {
        return Ok(Map::new());
    }

    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(other) => Err(ToolArgumentParseError::non_object(context, &other)),
        Err(e) => Err(ToolArgumentParseError::malformed_json(context, &e)),
    }
}

/// Validate that a string is valid tool invocation arguments JSON.
///
/// Returns `true` if the string is valid JSON that parses to an object,
/// or if the string is empty/null (treated as valid empty args).
pub fn is_valid_tool_call_arguments(args: Option<&str>) -> bool {
    let Some(args) = args else {
        return true;
    };

    let trimmed = args.trim();
    if trimmed.is_empty() {
        return true;
    }

    parse_tool_call_arguments(Some(trimmed), None).is_ok()
}

fn context_label(context: Option<&ToolCallContext>) -> String {
    let Some(context) = context else {
        return "provider tool invocation arguments".into();
    };

    let provider = context.provider.as_deref().unwrap_or("provider");
    let tool_name = context.tool_name.as_deref().unwrap_or("unknown tool");

    match context.invocation_id.as_deref() {
        Some(invocation_id) => {
            format!("{provider} tool invocation arguments for {tool_name} ({invocation_id})")
        }
        None => {
            format!("{provider} tool invocation arguments for {tool_name}")
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
        let result = parse_tool_call_arguments(Some(r#"{"file": "test.rs"}"#), None)
            .expect("valid object parses");
        assert_eq!(result.len(), 1);
        assert_eq!(result["file"], "test.rs");
    }

    #[test]
    fn parse_empty_object() {
        let result = parse_tool_call_arguments(Some("{}"), None).expect("empty object parses");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_none_returns_empty() {
        let result = parse_tool_call_arguments(None, None).expect("none is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_string_returns_empty() {
        let result = parse_tool_call_arguments(Some(""), None).expect("empty is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_whitespace_returns_empty() {
        let result =
            parse_tool_call_arguments(Some("  \n  "), None).expect("whitespace is empty args");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_invalid_json_fails_closed() {
        let err = parse_tool_call_arguments(Some("not json"), None)
            .expect_err("malformed arguments fail closed");
        assert!(err.to_string().contains("malformed JSON"));
        assert!(
            err.to_string()
                .contains("provider tool invocation arguments")
        );
    }

    #[test]
    fn parse_non_object_json_fails_closed() {
        let err = parse_tool_call_arguments(Some("[1,2,3]"), None)
            .expect_err("non-object arguments fail closed");
        assert!(err.to_string().contains("received array"));
    }

    #[test]
    fn parse_string_json_fails_closed() {
        let err = parse_tool_call_arguments(Some("\"just a string\""), None)
            .expect_err("string arguments fail closed");
        assert!(err.to_string().contains("received string"));
    }

    #[test]
    fn parse_complex_object() {
        let args = r#"{"command": "ls -la", "timeout": 5000, "cwd": "/home"}"#;
        let result = parse_tool_call_arguments(Some(args), None).expect("complex object parses");
        assert_eq!(result.len(), 3);
        assert_eq!(result["command"], "ls -la");
        assert_eq!(result["timeout"], 5000);
    }

    #[test]
    fn parse_with_context_logs() {
        let ctx = ToolCallContext {
            invocation_id: Some("toolu_123".into()),
            tool_name: Some("test_tool".into()),
            provider: Some("anthropic".into()),
        };
        let err = parse_tool_call_arguments(Some("broken{"), Some(&ctx))
            .expect_err("invalid JSON with context fails closed");
        let err = err.to_string();
        assert!(err.contains("anthropic tool invocation arguments"));
        assert!(err.contains("test_tool"));
        assert!(err.contains("toolu_123"));
    }

    #[test]
    fn parse_nested_objects() {
        let args = r#"{"outer": {"inner": "value"}}"#;
        let result = parse_tool_call_arguments(Some(args), None).expect("nested object parses");
        assert_eq!(result.len(), 1);
        assert!(result["outer"].is_object());
    }

    #[test]
    fn validate_valid_object() {
        assert!(is_valid_tool_call_arguments(Some(r#"{"a": 1}"#)));
    }

    #[test]
    fn validate_empty_is_valid() {
        assert!(is_valid_tool_call_arguments(None));
        assert!(is_valid_tool_call_arguments(Some("")));
    }

    #[test]
    fn validate_non_object_is_invalid() {
        assert!(!is_valid_tool_call_arguments(Some("[1,2]")));
        assert!(!is_valid_tool_call_arguments(Some("\"string\"")));
    }

    #[test]
    fn validate_invalid_json_is_invalid() {
        assert!(!is_valid_tool_call_arguments(Some("not json")));
    }
}
