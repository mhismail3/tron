use serde::{Deserialize, Serialize};

use crate::ids::SessionId;
use crate::security::ProviderType;

/// Per-turn token usage, raw from provider.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TokenUsage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cache_read_tokens: u32,
    pub cache_creation_tokens: u32,
    pub cache_creation_5m_tokens: u32,
    pub cache_creation_1h_tokens: u32,
    pub provider_type: ProviderType,
}

/// Immutable, canonical token record — full audit trail per LLM response.
/// Created once per turn, never modified.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TokenRecord {
    pub source: TokenSource,
    pub computed: ComputedTokens,
    pub meta: TokenMeta,
}

/// Raw values exactly as the provider returned them.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TokenSource {
    pub provider: ProviderType,
    pub timestamp: String,
    pub raw_input_tokens: u32,
    pub raw_output_tokens: u32,
    pub raw_cache_read_tokens: u32,
    pub raw_cache_creation_tokens: u32,
    pub raw_cache_creation_5m_tokens: u32,
    pub raw_cache_creation_1h_tokens: u32,
}

/// Normalized/derived values for cross-provider consistency.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ComputedTokens {
    /// Total context window consumption.
    /// Anthropic: input + cache_read + cache_creation (mutually exclusive, no double counting).
    /// OpenAI/Google: input (already includes full context).
    pub context_window_tokens: u32,
    /// Delta since last turn.
    pub new_input_tokens: i32,
    /// Previous turn's context_window_tokens (for delta calc).
    pub previous_context_baseline: u32,
    pub calculation_method: CalculationMethod,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CalculationMethod {
    AnthropicCacheAware,
    Direct,
}

/// Audit metadata attached to each token record.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TokenMeta {
    pub turn: u32,
    pub session_id: SessionId,
    pub extracted_at: String,
    pub normalized_at: String,
}

/// Session-level accumulated totals (incremented per turn).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct AccumulatedTokens {
    pub total_input_tokens: u64,
    pub total_output_tokens: u64,
    pub total_cache_read_tokens: u64,
    pub total_cache_creation_tokens: u64,
    pub last_turn_input_tokens: u32,
    pub total_cost_cents: f64,
    pub turn_count: u32,
}

impl TokenRecord {
    /// Create a token record from raw usage data.
    pub fn from_usage(
        usage: &TokenUsage,
        previous_context_baseline: u32,
        turn: u32,
        session_id: SessionId,
    ) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        let context_window_tokens = match usage.provider_type {
            ProviderType::Anthropic => {
                usage.input_tokens + usage.cache_read_tokens + usage.cache_creation_tokens
            }
            ProviderType::OpenAI | ProviderType::Google => usage.input_tokens,
        };

        Self {
            source: TokenSource {
                provider: usage.provider_type.clone(),
                timestamp: now.clone(),
                raw_input_tokens: usage.input_tokens,
                raw_output_tokens: usage.output_tokens,
                raw_cache_read_tokens: usage.cache_read_tokens,
                raw_cache_creation_tokens: usage.cache_creation_tokens,
                raw_cache_creation_5m_tokens: usage.cache_creation_5m_tokens,
                raw_cache_creation_1h_tokens: usage.cache_creation_1h_tokens,
            },
            computed: ComputedTokens {
                context_window_tokens,
                new_input_tokens: context_window_tokens as i32 - previous_context_baseline as i32,
                previous_context_baseline,
                calculation_method: match usage.provider_type {
                    ProviderType::Anthropic => CalculationMethod::AnthropicCacheAware,
                    _ => CalculationMethod::Direct,
                },
            },
            meta: TokenMeta {
                turn,
                session_id,
                extracted_at: now.clone(),
                normalized_at: now,
            },
        }
    }
}

impl AccumulatedTokens {
    /// Incorporate a new turn's token usage into session totals.
    pub fn accumulate(&mut self, record: &TokenRecord) {
        self.total_input_tokens += record.source.raw_input_tokens as u64;
        self.total_output_tokens += record.source.raw_output_tokens as u64;
        self.total_cache_read_tokens += record.source.raw_cache_read_tokens as u64;
        self.total_cache_creation_tokens += record.source.raw_cache_creation_tokens as u64;
        self.last_turn_input_tokens = record.computed.context_window_tokens;
        self.turn_count += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_context_window_calculation() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 500,
            cache_read_tokens: 2000,
            cache_creation_tokens: 3000,
            cache_creation_5m_tokens: 0,
            cache_creation_1h_tokens: 0,
            provider_type: ProviderType::Anthropic,
        };
        let record = TokenRecord::from_usage(&usage, 0, 1, SessionId::new());
        // Anthropic: input + cache_read + cache_creation
        assert_eq!(record.computed.context_window_tokens, 6000);
        assert_eq!(record.computed.new_input_tokens, 6000);
        assert_eq!(record.computed.calculation_method, CalculationMethod::AnthropicCacheAware);
    }

    #[test]
    fn openai_context_window_calculation() {
        let usage = TokenUsage {
            input_tokens: 5000,
            output_tokens: 500,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cache_creation_5m_tokens: 0,
            cache_creation_1h_tokens: 0,
            provider_type: ProviderType::OpenAI,
        };
        let record = TokenRecord::from_usage(&usage, 0, 1, SessionId::new());
        assert_eq!(record.computed.context_window_tokens, 5000);
        assert_eq!(record.computed.calculation_method, CalculationMethod::Direct);
    }

    #[test]
    fn new_input_tokens_delta() {
        let usage = TokenUsage {
            input_tokens: 3000,
            output_tokens: 200,
            cache_read_tokens: 1000,
            cache_creation_tokens: 500,
            cache_creation_5m_tokens: 0,
            cache_creation_1h_tokens: 0,
            provider_type: ProviderType::Anthropic,
        };
        let record = TokenRecord::from_usage(&usage, 4000, 2, SessionId::new());
        // context_window = 3000 + 1000 + 500 = 4500
        // delta = 4500 - 4000 = 500
        assert_eq!(record.computed.context_window_tokens, 4500);
        assert_eq!(record.computed.new_input_tokens, 500);
    }

    #[test]
    fn accumulated_tokens_multi_turn() {
        let session_id = SessionId::new();
        let mut acc = AccumulatedTokens::default();

        let r1 = TokenRecord::from_usage(
            &TokenUsage {
                input_tokens: 100,
                output_tokens: 50,
                cache_read_tokens: 200,
                cache_creation_tokens: 0,
                cache_creation_5m_tokens: 0,
                cache_creation_1h_tokens: 0,
                provider_type: ProviderType::Anthropic,
            },
            0,
            1,
            session_id.clone(),
        );
        acc.accumulate(&r1);

        let r2 = TokenRecord::from_usage(
            &TokenUsage {
                input_tokens: 150,
                output_tokens: 75,
                cache_read_tokens: 200,
                cache_creation_tokens: 50,
                cache_creation_5m_tokens: 0,
                cache_creation_1h_tokens: 0,
                provider_type: ProviderType::Anthropic,
            },
            300,
            2,
            session_id,
        );
        acc.accumulate(&r2);

        assert_eq!(acc.total_input_tokens, 250);
        assert_eq!(acc.total_output_tokens, 125);
        assert_eq!(acc.total_cache_read_tokens, 400);
        assert_eq!(acc.total_cache_creation_tokens, 50);
        assert_eq!(acc.last_turn_input_tokens, 400); // 150+200+50
        assert_eq!(acc.turn_count, 2);
    }

    #[test]
    fn serde_roundtrip() {
        let record = TokenRecord::from_usage(
            &TokenUsage {
                input_tokens: 1000,
                output_tokens: 500,
                cache_read_tokens: 2000,
                cache_creation_tokens: 0,
                cache_creation_5m_tokens: 0,
                cache_creation_1h_tokens: 0,
                provider_type: ProviderType::Anthropic,
            },
            0,
            1,
            SessionId::new(),
        );
        let json = serde_json::to_string(&record).unwrap();
        let parsed: TokenRecord = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.source.raw_input_tokens, 1000);
        assert_eq!(parsed.computed.context_window_tokens, 3000);
    }
}
