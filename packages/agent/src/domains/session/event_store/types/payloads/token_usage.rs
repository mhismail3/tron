//! Token usage tracking types.
//!
//! [`TokenUsage`] matches the TypeScript `TokenUsage` interface exactly,
//! with `camelCase` field naming for DTO parity.

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
    /// Provider-native cached input tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<i64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<i64>,
    /// 5-minute cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_5m_tokens: Option<i64>,
    /// 1-hour cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_1h_tokens: Option<i64>,
    /// Hidden reasoning output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_output_tokens: Option<i64>,
    /// Provider thinking tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thought_tokens: Option<i64>,
    /// Tool-use prompt tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_prompt_tokens: Option<i64>,
    /// Provider-reported total tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<i64>,
}

/// Aggregate token totals accumulated from multiple events.
///
/// Used by both the message reconstructor and the SQL token summary queries.
/// All fields are non-optional `i64` since they represent running sums.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenTotals {
    /// Total input tokens.
    pub input_tokens: i64,
    /// Total output tokens.
    pub output_tokens: i64,
    /// Total cache read tokens.
    pub cache_read_tokens: i64,
    /// Total cache creation tokens.
    pub cache_creation_tokens: i64,
}

/// Canonical token record with source, computed, metadata, and pricing fields.
pub type TokenRecord = crate::domains::model::tokens::types::TokenRecord;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn serde_roundtrip_full() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 500,
            cache_read_tokens: Some(200),
            cached_input_tokens: Some(200),
            cache_creation_tokens: Some(100),
            cache_creation_5m_tokens: Some(50),
            cache_creation_1h_tokens: Some(25),
            reasoning_output_tokens: Some(12),
            thought_tokens: Some(13),
            tool_use_prompt_tokens: Some(14),
            total_tokens: Some(1700),
        };
        let json = serde_json::to_value(&usage).unwrap();
        assert_eq!(json["inputTokens"], 1000);
        assert_eq!(json["outputTokens"], 500);
        assert_eq!(json["cacheReadTokens"], 200);
        assert_eq!(json["cachedInputTokens"], 200);
        assert_eq!(json["cacheCreationTokens"], 100);
        assert_eq!(json["cacheCreation5mTokens"], 50);
        assert_eq!(json["cacheCreation1hTokens"], 25);
        assert_eq!(json["reasoningOutputTokens"], 12);
        assert_eq!(json["thoughtTokens"], 13);
        assert_eq!(json["toolUsePromptTokens"], 14);
        assert_eq!(json["totalTokens"], 1700);

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
}
