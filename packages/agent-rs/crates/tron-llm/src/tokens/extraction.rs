//! Per-provider token extraction from API responses.
//!
//! Each LLM provider reports token usage differently. This module provides
//! functions to extract raw [`TokenSource`] values from provider-specific
//! response formats.

use tron_core::messages::ProviderType;

use super::errors::{Result, TokenError};
use super::types::TokenSource;

/// Metadata needed for token extraction context.
pub struct ExtractionMeta {
    /// Current turn number.
    pub turn: u64,
    /// Session identifier.
    pub session_id: String,
}

/// Anthropic `message_start.usage` fields.
#[derive(Debug, Default)]
pub struct AnthropicMessageStartUsage {
    /// Input tokens (new, not from cache).
    pub input_tokens: Option<u64>,
    /// Cache creation input tokens (aggregate).
    pub cache_creation_input_tokens: Option<u64>,
    /// Cache read input tokens.
    pub cache_read_input_tokens: Option<u64>,
    /// Per-TTL cache creation breakdown.
    pub cache_creation: Option<AnthropicCacheCreation>,
}

/// Anthropic per-TTL cache creation breakdown.
#[derive(Debug, Default)]
pub struct AnthropicCacheCreation {
    /// 5-minute TTL cache creation tokens.
    pub ephemeral_5m_input_tokens: u64,
    /// 1-hour TTL cache creation tokens.
    pub ephemeral_1h_input_tokens: u64,
}

/// Anthropic `message_delta.usage` fields.
#[derive(Debug, Default)]
pub struct AnthropicMessageDeltaUsage {
    /// Output tokens from the delta.
    pub output_tokens: Option<u64>,
}

/// `OpenAI` usage response.
#[derive(Debug, Default)]
pub struct OpenAiUsage {
    /// Total input tokens.
    pub input_tokens: Option<u64>,
    /// Output tokens.
    pub output_tokens: Option<u64>,
    /// Cached tokens from input details.
    pub cached_tokens: Option<u64>,
}

/// Google usage metadata.
#[derive(Debug, Default)]
pub struct GoogleUsageMetadata {
    /// Prompt/input token count.
    pub prompt_token_count: Option<u64>,
    /// Candidate/output token count.
    pub candidates_token_count: Option<u64>,
}

/// Extract token source from Anthropic API response.
///
/// # Errors
///
/// Returns [`TokenError::MissingData`] if both usage objects are missing.
pub fn extract_anthropic(
    start_usage: Option<&AnthropicMessageStartUsage>,
    delta_usage: Option<&AnthropicMessageDeltaUsage>,
    meta: &ExtractionMeta,
) -> Result<TokenSource> {
    if start_usage.is_none() && delta_usage.is_none() {
        return Err(TokenError::MissingData {
            provider: Some(ProviderType::Anthropic),
            turn: meta.turn,
            session_id: meta.session_id.clone(),
            has_partial_data: false,
        });
    }

    let start = start_usage.map_or_else(AnthropicMessageStartUsage::default, |s| {
        AnthropicMessageStartUsage {
            input_tokens: s.input_tokens,
            cache_creation_input_tokens: s.cache_creation_input_tokens,
            cache_read_input_tokens: s.cache_read_input_tokens,
            cache_creation: s.cache_creation.as_ref().map(|c| AnthropicCacheCreation {
                ephemeral_5m_input_tokens: c.ephemeral_5m_input_tokens,
                ephemeral_1h_input_tokens: c.ephemeral_1h_input_tokens,
            }),
        }
    });
    let delta = delta_usage.map_or_else(AnthropicMessageDeltaUsage::default, |d| {
        AnthropicMessageDeltaUsage {
            output_tokens: d.output_tokens,
        }
    });

    let input_tokens = start.input_tokens.unwrap_or(0);
    let cache_read = start.cache_read_input_tokens.unwrap_or(0);
    let cache_creation = start.cache_creation_input_tokens.unwrap_or(0);
    let output_tokens = delta.output_tokens.unwrap_or(0);

    let (cache_5min, cache_1hr) = match &start.cache_creation {
        Some(cc) => (cc.ephemeral_5m_input_tokens, cc.ephemeral_1h_input_tokens),
        None => (0, 0),
    };

    let now = chrono::Utc::now().to_rfc3339();

    Ok(TokenSource {
        provider: ProviderType::Anthropic,
        timestamp: now,
        raw_input_tokens: input_tokens,
        raw_output_tokens: output_tokens,
        raw_cache_read_tokens: cache_read,
        raw_cache_creation_tokens: cache_creation,
        raw_cache_creation_5m_tokens: cache_5min,
        raw_cache_creation_1h_tokens: cache_1hr,
    })
}

/// Extract token source from `OpenAI` API response.
///
/// # Errors
///
/// Returns [`TokenError::MissingData`] if usage is missing.
pub fn extract_openai(
    usage: Option<&OpenAiUsage>,
    meta: &ExtractionMeta,
    provider: ProviderType,
) -> Result<TokenSource> {
    let usage = usage.ok_or_else(|| TokenError::MissingData {
        provider: Some(provider.clone()),
        turn: meta.turn,
        session_id: meta.session_id.clone(),
        has_partial_data: false,
    })?;

    let now = chrono::Utc::now().to_rfc3339();

    Ok(TokenSource {
        provider,
        timestamp: now,
        raw_input_tokens: usage.input_tokens.unwrap_or(0),
        raw_output_tokens: usage.output_tokens.unwrap_or(0),
        raw_cache_read_tokens: usage.cached_tokens.unwrap_or(0),
        raw_cache_creation_tokens: 0,
        raw_cache_creation_5m_tokens: 0,
        raw_cache_creation_1h_tokens: 0,
    })
}

/// Extract token source from Google API response.
///
/// # Errors
///
/// Returns [`TokenError::MissingData`] if usage metadata is missing.
pub fn extract_google(
    usage_metadata: Option<&GoogleUsageMetadata>,
    meta: &ExtractionMeta,
) -> Result<TokenSource> {
    let usage = usage_metadata.ok_or_else(|| TokenError::MissingData {
        provider: Some(ProviderType::Google),
        turn: meta.turn,
        session_id: meta.session_id.clone(),
        has_partial_data: false,
    })?;

    let now = chrono::Utc::now().to_rfc3339();

    Ok(TokenSource {
        provider: ProviderType::Google,
        timestamp: now,
        raw_input_tokens: usage.prompt_token_count.unwrap_or(0),
        raw_output_tokens: usage.candidates_token_count.unwrap_or(0),
        raw_cache_read_tokens: 0,
        raw_cache_creation_tokens: 0,
        raw_cache_creation_5m_tokens: 0,
        raw_cache_creation_1h_tokens: 0,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn test_meta() -> ExtractionMeta {
        ExtractionMeta {
            turn: 1,
            session_id: "test-session".to_string(),
        }
    }

    // ── Anthropic extraction ──

    #[test]
    fn anthropic_basic_extraction() {
        let start = AnthropicMessageStartUsage {
            input_tokens: Some(604),
            cache_read_input_tokens: Some(8266),
            cache_creation_input_tokens: Some(0),
            cache_creation: None,
        };
        let delta = AnthropicMessageDeltaUsage {
            output_tokens: Some(100),
        };
        let source = extract_anthropic(Some(&start), Some(&delta), &test_meta()).unwrap();
        assert_eq!(source.provider, ProviderType::Anthropic);
        assert_eq!(source.raw_input_tokens, 604);
        assert_eq!(source.raw_output_tokens, 100);
        assert_eq!(source.raw_cache_read_tokens, 8266);
        assert_eq!(source.raw_cache_creation_tokens, 0);
    }

    #[test]
    fn anthropic_with_per_ttl_cache() {
        let start = AnthropicMessageStartUsage {
            input_tokens: Some(500),
            cache_creation_input_tokens: Some(200),
            cache_read_input_tokens: Some(0),
            cache_creation: Some(AnthropicCacheCreation {
                ephemeral_5m_input_tokens: 100,
                ephemeral_1h_input_tokens: 100,
            }),
        };
        let source = extract_anthropic(Some(&start), None, &test_meta()).unwrap();
        assert_eq!(source.raw_cache_creation_5m_tokens, 100);
        assert_eq!(source.raw_cache_creation_1h_tokens, 100);
        assert_eq!(source.raw_output_tokens, 0); // no delta
    }

    #[test]
    fn anthropic_missing_both_returns_error() {
        let result = extract_anthropic(None, None, &test_meta());
        assert!(result.is_err());
        match result.unwrap_err() {
            TokenError::MissingData {
                provider,
                has_partial_data,
                ..
            } => {
                assert_eq!(provider, Some(ProviderType::Anthropic));
                assert!(!has_partial_data);
            }
            _ => panic!("expected MissingData"),
        }
    }

    #[test]
    fn anthropic_start_only() {
        let start = AnthropicMessageStartUsage {
            input_tokens: Some(100),
            ..Default::default()
        };
        let source = extract_anthropic(Some(&start), None, &test_meta()).unwrap();
        assert_eq!(source.raw_input_tokens, 100);
        assert_eq!(source.raw_output_tokens, 0);
    }

    #[test]
    fn anthropic_delta_only() {
        let delta = AnthropicMessageDeltaUsage {
            output_tokens: Some(50),
        };
        let source = extract_anthropic(None, Some(&delta), &test_meta()).unwrap();
        assert_eq!(source.raw_input_tokens, 0);
        assert_eq!(source.raw_output_tokens, 50);
    }

    // ── OpenAI extraction ──

    #[test]
    fn openai_basic_extraction() {
        let usage = OpenAiUsage {
            input_tokens: Some(1000),
            output_tokens: Some(200),
            cached_tokens: Some(800),
        };
        let source = extract_openai(Some(&usage), &test_meta(), ProviderType::OpenAi).unwrap();
        assert_eq!(source.provider, ProviderType::OpenAi);
        assert_eq!(source.raw_input_tokens, 1000);
        assert_eq!(source.raw_output_tokens, 200);
        assert_eq!(source.raw_cache_read_tokens, 800);
        assert_eq!(source.raw_cache_creation_tokens, 0);
    }

    #[test]
    fn openai_codex_provider_type() {
        let usage = OpenAiUsage {
            input_tokens: Some(500),
            output_tokens: Some(100),
            cached_tokens: None,
        };
        let source = extract_openai(Some(&usage), &test_meta(), ProviderType::OpenAiCodex).unwrap();
        assert_eq!(source.provider, ProviderType::OpenAiCodex);
        assert_eq!(source.raw_cache_read_tokens, 0);
    }

    #[test]
    fn openai_missing_returns_error() {
        let result = extract_openai(None, &test_meta(), ProviderType::OpenAi);
        assert!(result.is_err());
    }

    // ── Google extraction ──

    #[test]
    fn google_basic_extraction() {
        let usage = GoogleUsageMetadata {
            prompt_token_count: Some(500),
            candidates_token_count: Some(200),
        };
        let source = extract_google(Some(&usage), &test_meta()).unwrap();
        assert_eq!(source.provider, ProviderType::Google);
        assert_eq!(source.raw_input_tokens, 500);
        assert_eq!(source.raw_output_tokens, 200);
        assert_eq!(source.raw_cache_read_tokens, 0);
    }

    #[test]
    fn google_missing_returns_error() {
        let result = extract_google(None, &test_meta());
        assert!(result.is_err());
    }

    #[test]
    fn google_partial_fields() {
        let usage = GoogleUsageMetadata {
            prompt_token_count: Some(300),
            candidates_token_count: None,
        };
        let source = extract_google(Some(&usage), &test_meta()).unwrap();
        assert_eq!(source.raw_input_tokens, 300);
        assert_eq!(source.raw_output_tokens, 0);
    }
}
