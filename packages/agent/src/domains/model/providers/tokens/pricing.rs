//! Model pricing tables and cost calculation.
//!
//! Pricing data is explicit per supported model. Cost calculation handles
//! Anthropic's per-TTL cache pricing (5-minute and 1-hour tiers), prompt-cache
//! hit/write buckets for cache-aware providers, and unavailable pricing for any
//! model not listed here.

use crate::shared::protocol::messages::TokenUsage;

use super::types::{PricingRecord, PricingTier, TokenCostBreakdown};

/// Look up the pricing tier for a model identifier.
///
/// Returns `None` for unknown models (no implicit default pricing).
#[must_use]
pub fn get_pricing_tier(model: &str) -> Option<PricingTier> {
    exact_match(model)
}

/// Calculate server-authoritative component pricing for a token record.
#[must_use]
#[allow(clippy::cast_precision_loss)] // Token counts never approach 2^52
pub fn calculate_pricing(model: &str, usage: &TokenUsage) -> PricingRecord {
    let Some(tier) = get_pricing_tier(model) else {
        return PricingRecord::unavailable(model, "unsupported_model_pricing");
    };
    let Some(provider) = usage.provider_type else {
        return PricingRecord::unavailable(model, "missing_provider_for_pricing");
    };
    if provider == crate::shared::protocol::messages::Provider::Unknown {
        return PricingRecord::unavailable(model, "unknown_provider_for_pricing");
    }

    let input = usage.input_tokens;
    let output = usage.output_tokens;
    let cache_read = usage
        .cache_read_tokens
        .or(usage.cached_input_tokens)
        .unwrap_or(0);
    let cache_creation = usage.cache_creation_tokens.unwrap_or(0);
    let cache_5min = usage.cache_creation_5m_tokens.unwrap_or(0);
    let cache_1hr = usage.cache_creation_1h_tokens.unwrap_or(0);

    let base_input = match provider {
        crate::shared::protocol::messages::Provider::Anthropic
        | crate::shared::protocol::messages::Provider::MiniMax => input,
        _ => input
            .saturating_sub(cache_read)
            .saturating_sub(cache_creation),
    };
    let base_input_cost = base_input as f64 / 1_000_000.0 * tier.input_per_million;

    // Cache creation cost: per-TTL if available, else aggregate
    let cache_creation_cost = if cache_5min > 0 || cache_1hr > 0 {
        let cost_5min = cache_5min as f64 / 1_000_000.0
            * tier.input_per_million
            * tier.cache_write_5m_multiplier;
        let cost_1hr = cache_1hr as f64 / 1_000_000.0
            * tier.input_per_million
            * tier.cache_write_1h_multiplier;
        cost_5min + cost_1hr
    } else {
        cache_creation as f64 / 1_000_000.0
            * tier.input_per_million
            * tier.cache_write_5m_multiplier
    };

    // Cache read cost (typically 90% discount)
    let cache_read_cost =
        cache_read as f64 / 1_000_000.0 * tier.input_per_million * tier.cache_read_multiplier;

    let input_cost = base_input_cost + cache_creation_cost + cache_read_cost;
    let output_cost = output as f64 / 1_000_000.0 * tier.output_per_million;
    let total = input_cost + output_cost;

    PricingRecord {
        available: true,
        model: model.to_string(),
        reason: None,
        cost: Some(TokenCostBreakdown {
            base_input_tokens: base_input,
            output_tokens: output,
            cache_read_tokens: cache_read,
            cache_write_tokens: cache_creation,
            cache_write_5m_tokens: cache_5min,
            cache_write_1h_tokens: cache_1hr,
            base_input_cost,
            output_cost,
            cache_read_cost,
            cache_write_cost: cache_creation_cost,
            total_cost: total,
            currency: "USD".to_string(),
        }),
    }
}

// ─── Internal helpers ────────────────────────────────────────────────────────

/// Create an Anthropic pricing tier.
fn anthropic_tier(input: f64, output: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.25,
        cache_write_1h_multiplier: 2.0,
        cache_read_multiplier: 0.1,
    }
}

/// Create a Google pricing tier.
fn google_tier(input: f64, output: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: 0.25,
    }
}

/// Create an `OpenAI` pricing tier with an explicit cached-input price.
fn openai_cached_tier(input: f64, output: f64, cached_input: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: cached_input / input,
    }
}

/// Create an `OpenAI` pricing tier for models without cached-input discount.
fn openai_uncached_tier(input: f64, output: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: 1.0,
    }
}

/// Exact model name matching.
fn exact_match(model: &str) -> Option<PricingTier> {
    Some(match model {
        // Anthropic — Opus 4.5/4.6
        "claude-opus-4-6" | "claude-opus-4-5" => anthropic_tier(5.0, 25.0),

        // Anthropic — Sonnet family ($3/$15)
        "claude-sonnet-4-6"
        | "claude-sonnet-4-5-20250929"
        | "claude-sonnet-4-5"
        | "claude-sonnet-4-0-20250514"
        | "claude-sonnet-4"
        | "claude-3-7-sonnet-20250219"
        | "claude-3-7-sonnet" => anthropic_tier(3.0, 15.0),

        // Anthropic — Haiku 4.5
        "claude-haiku-4-5-20251001" | "claude-haiku-4-5" => anthropic_tier(1.0, 5.0),

        // Anthropic — Opus 4/4.1 ($15/$75)
        "claude-opus-4-1-20250415"
        | "claude-opus-4-1"
        | "claude-opus-4-0-20250415"
        | "claude-opus-4" => anthropic_tier(15.0, 75.0),

        // Anthropic — Claude 3 Haiku
        "claude-3-haiku-20240307" | "claude-3-haiku" => anthropic_tier(0.25, 1.25),

        // Google — Gemini Pro
        "gemini-3-pro-preview" | "gemini-2-5-pro" | "gemini-2.5-pro" => google_tier(1.25, 5.0),

        // Google — Gemini 3.1 Flash Lite
        "gemini-3.1-flash-lite-preview" => google_tier(0.25, 1.50),

        // Google — Gemini Flash
        "gemini-3-flash-preview" | "gemini-2-5-flash" | "gemini-2.5-flash" => {
            google_tier(0.075, 0.3)
        }

        // OpenAI
        "o3" | "o3-2025-04-16" => openai_cached_tier(2.0, 8.0, 0.50),
        "o3-pro" | "o3-pro-2025-06-10" => openai_uncached_tier(20.0, 80.0),
        "o4-mini" | "o4-mini-2025-04-16" => openai_cached_tier(1.10, 4.40, 0.275),
        "o3-mini" | "o3-mini-2025-01-31" => openai_cached_tier(1.10, 4.40, 0.55),
        "o1" | "o1-2024-12-17" => openai_cached_tier(15.0, 60.0, 7.50),
        "o1-mini" | "o1-mini-2024-09-12" => openai_cached_tier(1.10, 4.40, 0.55),
        "o1-preview" | "o1-preview-2024-09-12" => openai_cached_tier(15.0, 60.0, 7.50),
        "o1-pro" | "o1-pro-2025-03-19" => openai_uncached_tier(150.0, 600.0),
        "gpt-4.1" | "gpt-4.1-2025-04-14" => openai_cached_tier(2.0, 8.0, 0.50),
        "gpt-4.1-mini" | "gpt-4.1-mini-2025-04-14" => openai_cached_tier(0.40, 1.60, 0.10),
        "gpt-4.1-nano" | "gpt-4.1-nano-2025-04-14" => openai_cached_tier(0.10, 0.40, 0.025),
        "gpt-4o" | "gpt-4o-2024-11-20" | "gpt-4o-2024-08-06" | "gpt-4o-2024-05-13" => {
            openai_cached_tier(2.50, 10.0, 1.25)
        }
        "gpt-4o-mini" | "gpt-4o-mini-2024-07-18" => openai_cached_tier(0.15, 0.60, 0.075),
        "gpt-4.5-preview" | "gpt-4.5-preview-2025-02-27" => openai_cached_tier(75.0, 150.0, 37.50),
        "gpt-4-turbo" | "gpt-4-turbo-2024-04-09" => openai_uncached_tier(10.0, 30.0),
        "gpt-4-turbo-preview" | "gpt-4-0125-preview" | "gpt-4-1106-preview" => {
            openai_uncached_tier(10.0, 30.0)
        }
        "gpt-4" | "gpt-4-0613" | "gpt-4-0314" => openai_uncached_tier(30.0, 60.0),
        "gpt-3.5-turbo" | "gpt-3.5-turbo-0125" | "gpt-3.5-turbo-1106" => {
            openai_uncached_tier(0.50, 1.50)
        }
        "gpt-5.5" | "gpt-5.5-2026-04-23" => openai_cached_tier(5.0, 30.0, 0.50),
        "gpt-5.5-pro" | "gpt-5.5-pro-2026-04-23" => openai_uncached_tier(30.0, 180.0),
        "gpt-5.4" | "gpt-5.4-2026-03-05" => openai_cached_tier(2.50, 15.0, 0.25),
        "gpt-5.4-pro" | "gpt-5.4-pro-2026-03-05" => openai_uncached_tier(30.0, 180.0),
        "gpt-5.4-mini" | "gpt-5.4-mini-2026-03-17" => openai_cached_tier(0.75, 4.50, 0.075),
        "gpt-5.4-nano" | "gpt-5.4-nano-2026-03-17" => openai_cached_tier(0.20, 1.25, 0.020),
        "gpt-5.2-pro" | "gpt-5.2-pro-2025-12-11" => openai_uncached_tier(21.0, 168.0),
        "gpt-5.3-codex" | "gpt-5.3-codex-spark" => openai_cached_tier(1.75, 14.0, 0.175),
        "gpt-5.2" | "gpt-5.2-2025-12-11" | "gpt-5.2-codex" => openai_cached_tier(1.75, 14.0, 0.175),
        "gpt-5.1" | "gpt-5.1-2025-11-13" => openai_cached_tier(1.25, 10.0, 0.125),
        "gpt-5" | "gpt-5-2025-08-07" => openai_cached_tier(1.25, 10.0, 0.125),
        "gpt-5-mini" | "gpt-5-mini-2025-08-07" => openai_cached_tier(0.25, 2.0, 0.025),
        "gpt-5-nano" | "gpt-5-nano-2025-08-07" => openai_cached_tier(0.05, 0.40, 0.005),
        "gpt-5-pro" | "gpt-5-pro-2025-10-06" => openai_uncached_tier(15.0, 120.0),
        "gpt-5-codex" | "gpt-5.1-codex" => openai_cached_tier(1.25, 10.0, 0.125),
        "gpt-5.1-codex-max" => openai_cached_tier(1.25, 10.0, 0.125),
        "gpt-5.1-codex-mini" => openai_cached_tier(0.25, 2.0, 0.025),
        "codex-mini-latest" => openai_cached_tier(1.50, 6.0, 0.375),
        "gpt-5.3-chat-latest" => openai_cached_tier(1.75, 14.0, 0.175),
        "gpt-5.2-chat-latest" => openai_cached_tier(1.75, 14.0, 0.175),
        "gpt-5.1-chat-latest" | "gpt-5-chat-latest" => openai_cached_tier(1.25, 10.0, 0.125),
        "chatgpt-4o-latest" => openai_uncached_tier(5.0, 15.0),
        "gpt-oss-120b" | "gpt-oss-20b" => openai_uncached_tier(0.0, 0.0),

        // MiniMax — Anthropic-compatible prompt caching.
        "MiniMax-M2.7" => minimax_tier(0.3, 1.2, 0.2),
        "MiniMax-M2.7-highspeed" => minimax_tier(0.3, 2.4, 0.2),
        "MiniMax-M2.5" | "MiniMax-M2.1" | "MiniMax-M2" => minimax_tier(0.3, 1.2, 0.1),
        "MiniMax-M2.5-highspeed" | "MiniMax-M2.1-highspeed" => minimax_tier(0.3, 2.4, 0.1),

        // Kimi — K2.6 / K2.5.
        "kimi-k2.6" => kimi_tier(0.95, 4.00, Some(0.16)),
        "kimi-k2.5" => kimi_tier(0.60, 3.00, Some(0.10)),

        // Kimi — K2 standard ($0.60/$2.50)
        "kimi-k2-0905-preview" | "kimi-k2-0711-preview" | "kimi-k2-thinking" => {
            kimi_tier(0.60, 2.50, Some(0.15))
        }

        // Kimi — K2 turbo ($1.15/$8.00)
        "kimi-k2-turbo-preview" | "kimi-k2-thinking-turbo" => kimi_tier(1.15, 8.00, Some(0.15)),

        // Kimi — Moonshot V1 retired generation.
        "moonshot-v1-8k" => kimi_tier(0.20, 2.00, None),
        "moonshot-v1-32k" => kimi_tier(1.00, 3.00, None),
        "moonshot-v1-128k" => kimi_tier(2.00, 5.00, None),

        // Ollama — local models (free)
        "gemma4:e4b" | "gemma4:26b" => free_tier(),

        _ => return None,
    })
}

/// Create a `MiniMax` pricing tier.
fn minimax_tier(input: f64, output: f64, cache_read_multiplier: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.25,
        cache_write_1h_multiplier: 1.25,
        cache_read_multiplier,
    }
}

/// Create a Kimi pricing tier.
fn kimi_tier(input: f64, output: f64, cache_read: Option<f64>) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: cache_read.map_or(1.0, |price| price / input),
    }
}

/// Create an Ollama pricing tier (local, free).
fn free_tier() -> PricingTier {
    PricingTier {
        input_per_million: 0.0,
        output_per_million: 0.0,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: 1.0,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::messages::Provider;

    fn assert_float_eq(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < f64::EPSILON,
            "expected {expected}, got {actual}"
        );
    }

    // ── Pricing tier lookup ──

    #[test]
    fn pricing_claude_opus_46() {
        let tier = get_pricing_tier("claude-opus-4-6").unwrap();
        assert_float_eq(tier.input_per_million, 5.0);
        assert_float_eq(tier.output_per_million, 25.0);
        assert_float_eq(tier.cache_write_5m_multiplier, 1.25);
        assert_float_eq(tier.cache_write_1h_multiplier, 2.0);
        assert_float_eq(tier.cache_read_multiplier, 0.1);
    }

    #[test]
    fn pricing_claude_sonnet_45() {
        let tier = get_pricing_tier("claude-sonnet-4-5-20250929").unwrap();
        assert_float_eq(tier.input_per_million, 3.0);
        assert_float_eq(tier.output_per_million, 15.0);
    }

    #[test]
    fn pricing_claude_haiku_45() {
        let tier = get_pricing_tier("claude-haiku-4-5-20251001").unwrap();
        assert_float_eq(tier.input_per_million, 1.0);
        assert_float_eq(tier.output_per_million, 5.0);
    }

    #[test]
    fn pricing_claude_opus_41() {
        let tier = get_pricing_tier("claude-opus-4-1").unwrap();
        assert_float_eq(tier.input_per_million, 15.0);
        assert_float_eq(tier.output_per_million, 75.0);
    }

    #[test]
    fn pricing_claude_3_haiku() {
        let tier = get_pricing_tier("claude-3-haiku").unwrap();
        assert_float_eq(tier.input_per_million, 0.25);
        assert_float_eq(tier.output_per_million, 1.25);
    }

    #[test]
    fn pricing_gemini_pro() {
        let tier = get_pricing_tier("gemini-3-pro-preview").unwrap();
        assert_float_eq(tier.input_per_million, 1.25);
        assert_float_eq(tier.output_per_million, 5.0);
        assert_float_eq(tier.cache_read_multiplier, 0.25);
    }

    #[test]
    fn pricing_gemini_flash() {
        let tier = get_pricing_tier("gemini-2-5-flash").unwrap();
        assert_float_eq(tier.input_per_million, 0.075);
        assert_float_eq(tier.output_per_million, 0.3);
    }

    #[test]
    fn pricing_o3() {
        let tier = get_pricing_tier("o3").unwrap();
        assert_float_eq(tier.input_per_million, 2.0);
        assert_float_eq(tier.output_per_million, 8.0);
        assert_float_eq(tier.cache_read_multiplier, 0.25);
    }

    #[test]
    fn pricing_gpt_55() {
        let tier = get_pricing_tier("gpt-5.5").unwrap();
        assert_float_eq(tier.input_per_million, 5.0);
        assert_float_eq(tier.output_per_million, 30.0);
        assert_float_eq(tier.cache_read_multiplier, 0.1);
    }

    #[test]
    fn pricing_gpt_54_variants() {
        let tier = get_pricing_tier("gpt-5.4").unwrap();
        assert_float_eq(tier.input_per_million, 2.50);
        assert_float_eq(tier.output_per_million, 15.0);

        let tier = get_pricing_tier("gpt-5.4-mini-2026-03-17").unwrap();
        assert_float_eq(tier.input_per_million, 0.75);
        assert_float_eq(tier.output_per_million, 4.50);

        let tier = get_pricing_tier("gpt-5.4-nano").unwrap();
        assert_float_eq(tier.input_per_million, 0.20);
        assert_float_eq(tier.output_per_million, 1.25);
    }

    #[test]
    fn pricing_gpt_52_and_retired_alias() {
        let tier = get_pricing_tier("gpt-5.2").unwrap();
        assert_float_eq(tier.input_per_million, 1.75);
        assert_float_eq(tier.output_per_million, 14.0);

        let alias_tier = get_pricing_tier("gpt-5.2-codex").unwrap();
        assert_float_eq(alias_tier.input_per_million, 1.75);
        assert_float_eq(alias_tier.output_per_million, 14.0);
    }

    #[test]
    fn pricing_expanded_openai_models() {
        let tier = get_pricing_tier("gpt-5-pro").unwrap();
        assert_float_eq(tier.input_per_million, 15.0);
        assert_float_eq(tier.output_per_million, 120.0);

        let tier = get_pricing_tier("gpt-5-mini").unwrap();
        assert_float_eq(tier.input_per_million, 0.25);
        assert_float_eq(tier.output_per_million, 2.0);

        let tier = get_pricing_tier("gpt-4.1-mini").unwrap();
        assert_float_eq(tier.input_per_million, 0.40);
        assert_float_eq(tier.output_per_million, 1.60);

        let tier = get_pricing_tier("codex-mini-latest").unwrap();
        assert_float_eq(tier.input_per_million, 1.50);
        assert_float_eq(tier.output_per_million, 6.0);

        let tier = get_pricing_tier("o1-pro").unwrap();
        assert_float_eq(tier.input_per_million, 150.0);
        assert_float_eq(tier.output_per_million, 600.0);
    }

    #[test]
    fn pricing_unknown_returns_none() {
        assert!(get_pricing_tier("some-unknown-model").is_none());
    }

    #[test]
    fn pricing_does_not_guess_partial_names() {
        assert!(get_pricing_tier("claude-opus-4-6-extended").is_none());
        assert!(get_pricing_tier("gemini-2-5-pro-latest").is_none());
    }

    #[test]
    fn pricing_simple_no_cache() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 100_000,
            provider_type: Some(Provider::Anthropic),
            ..Default::default()
        };
        let cost = calculate_pricing("claude-sonnet-4-5", &usage).cost.unwrap();
        assert!((cost.base_input_cost - 3.0).abs() < 0.001); // 1M * $3/M
        assert!((cost.output_cost - 1.5).abs() < 0.001); // 100K * $15/M
        assert!((cost.total_cost - 4.5).abs() < 0.001);
        assert_eq!(cost.currency, "USD");
    }

    #[test]
    fn pricing_with_cache_aggregate() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 100_000,
            cache_read_tokens: Some(800_000),
            cache_creation_tokens: Some(100_000),
            provider_type: Some(Provider::OpenAi),
            ..Default::default()
        };
        let cost = calculate_pricing("gpt-5.5", &usage).cost.unwrap();

        // base = 1M - 800K - 100K = 100K @ $5/M = $0.50
        // cache creation = 100K @ $5/M = $0.50
        // cache read = 800K @ $5/M * 0.1 = $0.40
        // output = 100K @ $30/M = $3.00
        let expected_input = 0.50 + 0.50 + 0.40;
        let actual_input = cost.base_input_cost + cost.cache_write_cost + cost.cache_read_cost;
        assert!((actual_input - expected_input).abs() < 0.001);
        assert!((cost.output_cost - 3.0).abs() < 0.001);
    }

    #[test]
    fn pricing_with_per_ttl_cache() {
        let usage = TokenUsage {
            input_tokens: 500_000,
            output_tokens: 50_000,
            cache_read_tokens: Some(0),
            cache_creation_tokens: Some(200_000),
            cache_creation_5m_tokens: Some(100_000),
            cache_creation_1h_tokens: Some(100_000),
            provider_type: Some(Provider::Anthropic),
            ..Default::default()
        };
        let cost = calculate_pricing("claude-opus-4-6", &usage).cost.unwrap();

        // Per-TTL takes precedence over aggregate
        // 5m: 100K @ $5/M * 1.25 = $0.625
        // 1h: 100K @ $5/M * 2.0 = $1.00
        // cache creation total = $1.625
        // Anthropic input_tokens already excludes cache write/read buckets.
        // base = 500K @ $5/M = $2.50
        // cache read = 0
        // output = 50K @ $25/M = $1.25
        let expected_input = 2.50 + 0.625 + 1.00;
        let actual_input = cost.base_input_cost + cost.cache_write_cost + cost.cache_read_cost;
        assert!((actual_input - expected_input).abs() < 0.001);
        assert!((cost.output_cost - 1.25).abs() < 0.001);
    }

    #[test]
    fn pricing_anthropic_base_input_uses_uncached_input_bucket() {
        let usage = TokenUsage {
            input_tokens: 100_000,
            output_tokens: 100_000,
            cache_read_tokens: Some(800_000),
            cache_creation_tokens: Some(100_000),
            provider_type: Some(Provider::Anthropic),
            ..Default::default()
        };
        let cost = calculate_pricing("claude-sonnet-4-5", &usage).cost.unwrap();

        // Anthropic input_tokens already excludes cache read/write buckets.
        let expected_input = 0.30 + 0.375 + 0.24;
        let actual_input = cost.base_input_cost + cost.cache_write_cost + cost.cache_read_cost;
        assert!((actual_input - expected_input).abs() < 0.001);
        assert!((cost.output_cost - 1.5).abs() < 0.001);
    }

    #[test]
    fn pricing_zero_usage() {
        let usage = TokenUsage {
            provider_type: Some(Provider::Anthropic),
            ..Default::default()
        };
        let cost = calculate_pricing("claude-opus-4-6", &usage).cost.unwrap();
        assert_float_eq(cost.total_cost, 0.0);
    }

    #[test]
    fn pricing_base_input_saturates_to_zero() {
        // When cache read + creation > input, base should not go negative
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 0,
            cache_read_tokens: Some(200),
            cache_creation_tokens: Some(200),
            provider_type: Some(Provider::OpenAi),
            ..Default::default()
        };
        let cost = calculate_pricing("gpt-5.5", &usage).cost.unwrap();
        // Base input saturates to 0, but cache costs are still counted
        assert!(cost.base_input_cost >= 0.0);
        assert!(cost.total_cost >= 0.0);
    }

    #[test]
    fn cost_missing_provider_returns_unavailable() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 1000,
            ..Default::default()
        };
        let pricing = calculate_pricing("claude-sonnet-4-5", &usage);
        assert!(!pricing.available);
        assert_eq!(
            pricing.reason.as_deref(),
            Some("missing_provider_for_pricing")
        );
    }

    #[test]
    fn pricing_unknown_model_returns_unavailable() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 1000,
            provider_type: Some(Provider::Anthropic),
            ..Default::default()
        };
        let pricing = calculate_pricing("totally-unknown-model", &usage);
        assert!(!pricing.available);
        assert_eq!(pricing.reason.as_deref(), Some("unsupported_model_pricing"));
    }

    #[test]
    fn pricing_minimax_m2_5() {
        let tier = get_pricing_tier("MiniMax-M2.5").unwrap();
        assert!((tier.input_per_million - 0.3).abs() < f64::EPSILON);
        assert!((tier.output_per_million - 1.2).abs() < f64::EPSILON);
        assert!((tier.cache_read_multiplier - 0.1).abs() < f64::EPSILON);
        assert!((tier.cache_write_5m_multiplier - 1.25).abs() < f64::EPSILON);
    }

    #[test]
    fn pricing_minimax_m2_7_has_explicit_read_price() {
        let tier = get_pricing_tier("MiniMax-M2.7").unwrap();
        assert_float_eq(tier.input_per_million, 0.3);
        assert_float_eq(tier.output_per_million, 1.2);
        assert_float_eq(tier.cache_read_multiplier, 0.2);
    }

    #[test]
    fn pricing_kimi_cache_hit_rates_are_explicit() {
        let tier = get_pricing_tier("kimi-k2.6").unwrap();
        assert_float_eq(tier.input_per_million, 0.95);
        assert_float_eq(tier.output_per_million, 4.0);
        assert!((tier.cache_read_multiplier - (0.16 / 0.95)).abs() < f64::EPSILON);
    }

    // ── Ollama ──

    #[test]
    fn pricing_ollama_free() {
        let tier = get_pricing_tier("gemma4:e4b").unwrap();
        assert_float_eq(tier.input_per_million, 0.0);
        assert_float_eq(tier.output_per_million, 0.0);
    }

    #[test]
    fn pricing_ollama_is_zero() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 500_000,
            provider_type: Some(Provider::Ollama),
            ..Default::default()
        };
        let cost = calculate_pricing("gemma4:e4b", &usage).cost.unwrap();
        assert_float_eq(cost.total_cost, 0.0);
        assert_float_eq(cost.base_input_cost, 0.0);
        assert_float_eq(cost.output_cost, 0.0);
    }
}
