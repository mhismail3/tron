//! Core token tracking types.
//!
//! These types model the immutable per-turn token record pipeline:
//! raw provider data ([`TokenSource`]) → computed values ([`ComputedTokens`])
//! → audit metadata ([`TokenMeta`]) → combined [`TokenRecord`].
//!
//! Session-level aggregates ([`AccumulatedTokens`], [`ContextWindowState`],
//! [`TokenState`]) are managed by the state module.

use serde::{Deserialize, Serialize};
use tron_core::messages::ProviderType;

/// Raw token values directly from the provider API response.
///
/// These values are immutable and represent exactly what the provider
/// reported — no computation or normalization applied.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenSource {
    /// Which provider reported these values.
    pub provider: ProviderType,
    /// ISO 8601 timestamp when tokens were extracted.
    pub timestamp: String,
    /// Raw input tokens from the API response.
    pub raw_input_tokens: u64,
    /// Raw output tokens from the API response.
    pub raw_output_tokens: u64,
    /// Tokens read from prompt cache.
    pub raw_cache_read_tokens: u64,
    /// Tokens written to prompt cache (aggregate).
    pub raw_cache_creation_tokens: u64,
    /// 5-minute TTL cache creation tokens (Anthropic per-TTL breakdown).
    pub raw_cache_creation_5m_tokens: u64,
    /// 1-hour TTL cache creation tokens (Anthropic per-TTL breakdown).
    pub raw_cache_creation_1h_tokens: u64,
}

/// Method used to calculate context window size.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CalculationMethod {
    /// Anthropic: `input + cache_read + cache_creation` (three mutually exclusive buckets).
    AnthropicCacheAware,
    /// Other providers: `input_tokens` directly is the full context.
    Direct,
}

/// Computed (derived) token values from normalization.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComputedTokens {
    /// Total tokens in the context window (provider-aware calculation).
    pub context_window_tokens: u64,
    /// Per-turn delta: new input tokens added this turn.
    pub new_input_tokens: u64,
    /// Previous context baseline used for delta calculation.
    pub previous_context_baseline: u64,
    /// Which calculation method was used.
    pub calculation_method: CalculationMethod,
}

/// Audit trail metadata for a token record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenMeta {
    /// Turn number within the session.
    pub turn: u64,
    /// Session identifier.
    pub session_id: String,
    /// ISO 8601 timestamp when tokens were extracted from the provider.
    pub extracted_at: String,
    /// ISO 8601 timestamp when normalization was performed.
    pub normalized_at: String,
}

/// Complete per-turn token record: source + computed + metadata.
///
/// Immutable once created. Provides a full audit trail for every
/// turn's token usage.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenRecord {
    /// Raw values from the provider.
    pub source: TokenSource,
    /// Computed/derived values.
    pub computed: ComputedTokens,
    /// Audit metadata.
    pub meta: TokenMeta,
}

/// Session-level accumulated token totals (mutable running sums).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccumulatedTokens {
    /// Total input tokens across all turns.
    pub input_tokens: u64,
    /// Total output tokens across all turns.
    pub output_tokens: u64,
    /// Total cache read tokens across all turns.
    pub cache_read_tokens: u64,
    /// Total cache creation tokens across all turns.
    pub cache_creation_tokens: u64,
    /// Total 5-minute TTL cache creation tokens.
    pub cache_creation_5m_tokens: u64,
    /// Total 1-hour TTL cache creation tokens.
    pub cache_creation_1h_tokens: u64,
    /// Total cost in USD.
    pub cost: f64,
}

/// Current context window tracking state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextWindowState {
    /// Tokens currently in the context window.
    pub current_size: u64,
    /// Maximum context window size for the model.
    pub max_size: u64,
    /// Percentage of context used (0.0–100.0).
    pub percent_used: f64,
    /// Tokens remaining before context limit.
    pub tokens_remaining: u64,
}

impl ContextWindowState {
    /// Create a new context window state with the given max size.
    pub fn new(max_size: u64) -> Self {
        Self {
            current_size: 0,
            max_size,
            percent_used: 0.0,
            tokens_remaining: max_size,
        }
    }

    /// Recalculate derived fields from current/max.
    #[allow(clippy::cast_precision_loss)] // Token counts never approach 2^52
    pub fn recalculate(&mut self) {
        if self.max_size > 0 {
            self.percent_used =
                (self.current_size as f64 / self.max_size as f64 * 100.0).min(100.0);
        } else {
            self.percent_used = 0.0;
        }
        self.tokens_remaining = self.max_size.saturating_sub(self.current_size);
    }
}

/// Complete session-level token state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenState {
    /// Most recent turn's record (if any turns have been processed).
    pub current: Option<TokenRecord>,
    /// Session-level accumulated totals.
    pub accumulated: AccumulatedTokens,
    /// Context window progress.
    pub context_window: ContextWindowState,
    /// Full audit trail of all turn records.
    pub history: Vec<TokenRecord>,
}

impl TokenState {
    /// Create an empty token state with the given context window limit.
    pub fn new(max_context_size: u64) -> Self {
        Self {
            current: None,
            accumulated: AccumulatedTokens::default(),
            context_window: ContextWindowState::new(max_context_size),
            history: Vec::new(),
        }
    }
}

/// Pricing tier for a model family.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PricingTier {
    /// Cost per million input tokens (USD).
    pub input_per_million: f64,
    /// Cost per million output tokens (USD).
    pub output_per_million: f64,
    /// Multiplier for 5-minute TTL cache writes (e.g., 1.25 for Anthropic).
    pub cache_write_5m_multiplier: f64,
    /// Multiplier for 1-hour TTL cache writes (e.g., 2.0 for Anthropic).
    pub cache_write_1h_multiplier: f64,
    /// Multiplier for cache reads (e.g., 0.1 for 90% discount).
    pub cache_read_multiplier: f64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_source_serde_roundtrip() {
        let source = TokenSource {
            provider: ProviderType::Anthropic,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            raw_input_tokens: 604,
            raw_output_tokens: 100,
            raw_cache_read_tokens: 8266,
            raw_cache_creation_tokens: 0,
            raw_cache_creation_5m_tokens: 0,
            raw_cache_creation_1h_tokens: 0,
        };
        let json = serde_json::to_value(&source).unwrap();
        assert_eq!(json["provider"], "anthropic");
        assert_eq!(json["rawInputTokens"], 604);
        assert_eq!(json["rawCacheReadTokens"], 8266);
        let back: TokenSource = serde_json::from_value(json).unwrap();
        assert_eq!(back, source);
    }

    #[test]
    fn calculation_method_serde() {
        assert_eq!(
            serde_json::to_string(&CalculationMethod::AnthropicCacheAware).unwrap(),
            "\"anthropic_cache_aware\""
        );
        assert_eq!(
            serde_json::to_string(&CalculationMethod::Direct).unwrap(),
            "\"direct\""
        );
    }

    #[test]
    fn computed_tokens_serde_roundtrip() {
        let computed = ComputedTokens {
            context_window_tokens: 8870,
            new_input_tokens: 102,
            previous_context_baseline: 8768,
            calculation_method: CalculationMethod::AnthropicCacheAware,
        };
        let json = serde_json::to_value(&computed).unwrap();
        assert_eq!(json["contextWindowTokens"], 8870);
        assert_eq!(json["calculationMethod"], "anthropic_cache_aware");
        let back: ComputedTokens = serde_json::from_value(json).unwrap();
        assert_eq!(back, computed);
    }

    #[test]
    fn token_meta_serde_roundtrip() {
        let meta = TokenMeta {
            turn: 2,
            session_id: "sess_abc".to_string(),
            extracted_at: "2024-01-15T12:00:00Z".to_string(),
            normalized_at: "2024-01-15T12:00:01Z".to_string(),
        };
        let json = serde_json::to_value(&meta).unwrap();
        assert_eq!(json["turn"], 2);
        assert_eq!(json["sessionId"], "sess_abc");
        let back: TokenMeta = serde_json::from_value(json).unwrap();
        assert_eq!(back, meta);
    }

    #[test]
    fn token_record_serde_roundtrip() {
        let record = TokenRecord {
            source: TokenSource {
                provider: ProviderType::Google,
                timestamp: "2024-01-15T12:00:00Z".to_string(),
                raw_input_tokens: 500,
                raw_output_tokens: 200,
                raw_cache_read_tokens: 0,
                raw_cache_creation_tokens: 0,
                raw_cache_creation_5m_tokens: 0,
                raw_cache_creation_1h_tokens: 0,
            },
            computed: ComputedTokens {
                context_window_tokens: 500,
                new_input_tokens: 500,
                previous_context_baseline: 0,
                calculation_method: CalculationMethod::Direct,
            },
            meta: TokenMeta {
                turn: 1,
                session_id: "s".to_string(),
                extracted_at: "2024-01-15T12:00:00Z".to_string(),
                normalized_at: "2024-01-15T12:00:00Z".to_string(),
            },
        };
        let json = serde_json::to_string(&record).unwrap();
        let back: TokenRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(back, record);
    }

    #[test]
    fn accumulated_tokens_default() {
        let acc = AccumulatedTokens::default();
        assert_eq!(acc.input_tokens, 0);
        assert_eq!(acc.output_tokens, 0);
        assert_eq!(acc.cache_read_tokens, 0);
        assert_eq!(acc.cost, 0.0);
    }

    #[test]
    fn context_window_state_new() {
        let cw = ContextWindowState::new(200_000);
        assert_eq!(cw.current_size, 0);
        assert_eq!(cw.max_size, 200_000);
        assert_eq!(cw.percent_used, 0.0);
        assert_eq!(cw.tokens_remaining, 200_000);
    }

    #[test]
    fn context_window_recalculate() {
        let mut cw = ContextWindowState::new(200_000);
        cw.current_size = 50_000;
        cw.recalculate();
        assert!((cw.percent_used - 25.0).abs() < 0.01);
        assert_eq!(cw.tokens_remaining, 150_000);
    }

    #[test]
    fn context_window_recalculate_overflow() {
        let mut cw = ContextWindowState::new(100);
        cw.current_size = 150; // Exceeds max
        cw.recalculate();
        assert!((cw.percent_used - 100.0).abs() < 0.01);
        assert_eq!(cw.tokens_remaining, 0);
    }

    #[test]
    fn context_window_zero_max() {
        let mut cw = ContextWindowState::new(0);
        cw.recalculate();
        assert_eq!(cw.percent_used, 0.0);
        assert_eq!(cw.tokens_remaining, 0);
    }

    #[test]
    fn token_state_new() {
        let state = TokenState::new(200_000);
        assert!(state.current.is_none());
        assert!(state.history.is_empty());
        assert_eq!(state.context_window.max_size, 200_000);
    }

    #[test]
    fn pricing_tier_serde_roundtrip() {
        let tier = PricingTier {
            input_per_million: 3.0,
            output_per_million: 15.0,
            cache_write_5m_multiplier: 1.25,
            cache_write_1h_multiplier: 2.0,
            cache_read_multiplier: 0.1,
        };
        let json = serde_json::to_value(&tier).unwrap();
        assert_eq!(json["inputPerMillion"], 3.0);
        assert_eq!(json["cacheWrite5mMultiplier"], 1.25);
        let back: PricingTier = serde_json::from_value(json).unwrap();
        assert_eq!(back, tier);
    }
}
