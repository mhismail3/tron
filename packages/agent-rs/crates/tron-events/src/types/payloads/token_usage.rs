//! Token usage tracking types.
//!
//! [`TokenUsage`] matches the TypeScript `TokenUsage` interface exactly,
//! with `camelCase` field naming for wire compatibility.

use serde::{Deserialize, Serialize};

/// Token usage reported by LLM providers.
///
/// All fields use `camelCase` serialization to match the TypeScript/iOS
/// wire format. Optional cache fields are omitted from JSON when `None`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    /// Number of input tokens consumed.
    pub input_tokens: i64,
    /// Number of output tokens generated.
    pub output_tokens: i64,
    /// Tokens read from prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<i64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<i64>,
    /// 5-minute cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_5m_tokens: Option<i64>,
    /// 1-hour cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_1h_tokens: Option<i64>,
}

/// Canonical token record with source, computed, and metadata fields.
///
/// Stored as `tokenRecord` on assistant message and streaming turn-end events.
/// Kept as opaque JSON because the schema is defined in `tron-tokens` crate.
pub type TokenRecord = serde_json::Value;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn default_is_zero() {
        let usage = TokenUsage::default();
        assert_eq!(usage.input_tokens, 0);
        assert_eq!(usage.output_tokens, 0);
        assert_eq!(usage.cache_read_tokens, None);
        assert_eq!(usage.cache_creation_tokens, None);
        assert_eq!(usage.cache_creation_5m_tokens, None);
        assert_eq!(usage.cache_creation_1h_tokens, None);
    }

    #[test]
    fn serde_roundtrip_full() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 500,
            cache_read_tokens: Some(200),
            cache_creation_tokens: Some(100),
            cache_creation_5m_tokens: Some(50),
            cache_creation_1h_tokens: Some(25),
        };
        let json = serde_json::to_value(&usage).unwrap();
        assert_eq!(json["inputTokens"], 1000);
        assert_eq!(json["outputTokens"], 500);
        assert_eq!(json["cacheReadTokens"], 200);
        assert_eq!(json["cacheCreationTokens"], 100);
        assert_eq!(json["cacheCreation5mTokens"], 50);
        assert_eq!(json["cacheCreation1hTokens"], 25);

        let back: TokenUsage = serde_json::from_value(json).unwrap();
        assert_eq!(usage, back);
    }

    #[test]
    fn serde_optional_fields_omitted() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            ..Default::default()
        };
        let json = serde_json::to_value(&usage).unwrap();
        assert_eq!(json["inputTokens"], 100);
        assert_eq!(json["outputTokens"], 50);
        assert!(json.get("cacheReadTokens").is_none());
        assert!(json.get("cacheCreationTokens").is_none());
        assert!(json.get("cacheCreation5mTokens").is_none());
        assert!(json.get("cacheCreation1hTokens").is_none());
    }

    #[test]
    fn deserialize_with_missing_optional_fields() {
        let json = json!({
            "inputTokens": 42,
            "outputTokens": 7
        });
        let usage: TokenUsage = serde_json::from_value(json).unwrap();
        assert_eq!(usage.input_tokens, 42);
        assert_eq!(usage.output_tokens, 7);
        assert_eq!(usage.cache_read_tokens, None);
    }

    #[test]
    fn deserialize_from_ts_wire_format() {
        let json_str = r#"{"inputTokens":5000,"outputTokens":2000,"cacheReadTokens":1000}"#;
        let usage: TokenUsage = serde_json::from_str(json_str).unwrap();
        assert_eq!(usage.input_tokens, 5000);
        assert_eq!(usage.output_tokens, 2000);
        assert_eq!(usage.cache_read_tokens, Some(1000));
        assert_eq!(usage.cache_creation_tokens, None);
    }

    #[test]
    fn clone_and_eq() {
        let a = TokenUsage {
            input_tokens: 10,
            output_tokens: 20,
            ..Default::default()
        };
        let b = a.clone();
        assert_eq!(a, b);
    }
}
