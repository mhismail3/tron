//! # ModelCapability Call Argument Parsing
//!
//! Safe JSON parsing for capability invocation arguments received from LLM providers.
//! Handles malformed JSON gracefully — returns empty object rather than erroring,
//! since incomplete capability invocations are common during streaming.

use serde_json::{Map, Value};
use tracing::debug;

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

/// Parse capability invocation arguments JSON string into a `Map`.
///
/// Fails open: returns an empty map on parse failure rather than propagating
/// errors, since the agent can still attempt to execute the tool with no args.
///
/// # Arguments
/// * `args` - Raw JSON string from the provider (may be empty, null, or malformed)
/// * `context` - Optional context for warning logs on parse failure
pub fn parse_capability_call_arguments(
    args: Option<&str>,
    context: Option<&CapabilityCallContext>,
) -> Map<String, Value> {
    let Some(args) = args else {
        return Map::new();
    };

    let trimmed = args.trim();
    if trimmed.is_empty() {
        return Map::new();
    }

    match serde_json::from_str::<Value>(trimmed) {
        Ok(Value::Object(map)) => map,
        Ok(other) => {
            debug!(
                invocation_id = context.and_then(|c| c.invocation_id.as_deref()),
                model_primitive_name = context.and_then(|c| c.model_primitive_name.as_deref()),
                provider = context.and_then(|c| c.provider.as_deref()),
                parsed_type = other.to_string().chars().take(20).collect::<String>(),
                "Capability invocation arguments parsed as non-object, wrapping"
            );
            Map::new()
        }
        Err(e) => {
            debug!(
                invocation_id = context.and_then(|c| c.invocation_id.as_deref()),
                model_primitive_name = context.and_then(|c| c.model_primitive_name.as_deref()),
                provider = context.and_then(|c| c.provider.as_deref()),
                error = %e,
                args_preview = crate::shared::text::truncate_str(trimmed, 100),
                "Failed to parse capability invocation arguments, returning empty object"
            );
            Map::new()
        }
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

    matches!(serde_json::from_str::<Value>(trimmed), Ok(Value::Object(_)))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_json_object() {
        let result = parse_capability_call_arguments(Some(r#"{"file": "test.rs"}"#), None);
        assert_eq!(result.len(), 1);
        assert_eq!(result["file"], "test.rs");
    }

    #[test]
    fn parse_empty_object() {
        let result = parse_capability_call_arguments(Some("{}"), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_none_returns_empty() {
        let result = parse_capability_call_arguments(None, None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_string_returns_empty() {
        let result = parse_capability_call_arguments(Some(""), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_whitespace_returns_empty() {
        let result = parse_capability_call_arguments(Some("  \n  "), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_invalid_json_returns_empty() {
        let result = parse_capability_call_arguments(Some("not json"), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_non_object_json_returns_empty() {
        let result = parse_capability_call_arguments(Some("[1,2,3]"), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_string_json_returns_empty() {
        let result = parse_capability_call_arguments(Some("\"just a string\""), None);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_complex_object() {
        let args = r#"{"command": "ls -la", "timeout": 5000, "cwd": "/home"}"#;
        let result = parse_capability_call_arguments(Some(args), None);
        assert_eq!(result.len(), 3);
        assert_eq!(result["command"], "ls -la");
        assert_eq!(result["timeout"], 5000);
    }

    #[test]
    fn parse_with_context_logs() {
        let ctx = CapabilityCallContext {
            invocation_id: Some("toolu_123".into()),
            model_primitive_name: Some("process::run".into()),
            provider: Some("anthropic".into()),
        };
        // Invalid JSON with context — should still return empty
        let result = parse_capability_call_arguments(Some("broken{"), Some(&ctx));
        assert!(result.is_empty());
    }

    #[test]
    fn parse_nested_objects() {
        let args = r#"{"outer": {"inner": "value"}}"#;
        let result = parse_capability_call_arguments(Some(args), None);
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
