//! Cost calculation — pricing tables and per-request cost computation.
//!
//! Pricing tiers are per-million tokens with cache multipliers.

use tron_core::messages::TokenUsage;

/// Pricing tier per million tokens.
struct PricingTier {
    input_per_million: f64,
    output_per_million: f64,
    cache_write_5m_multiplier: f64,
    cache_write_1h_multiplier: f64,
    cache_read_multiplier: f64,
}

// ─── Anthropic ───────────────────────────────────────────────────────────────

const OPUS_4_6: PricingTier = PricingTier {
    input_per_million: 5.0,
    output_per_million: 25.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const OPUS_4_5: PricingTier = PricingTier {
    input_per_million: 5.0,
    output_per_million: 25.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const SONNET_4_5: PricingTier = PricingTier {
    input_per_million: 3.0,
    output_per_million: 15.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const HAIKU_4_5: PricingTier = PricingTier {
    input_per_million: 1.0,
    output_per_million: 5.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const OPUS_4_1: PricingTier = PricingTier {
    input_per_million: 15.0,
    output_per_million: 75.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const OPUS_4: PricingTier = PricingTier {
    input_per_million: 15.0,
    output_per_million: 75.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const SONNET_4: PricingTier = PricingTier {
    input_per_million: 3.0,
    output_per_million: 15.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const SONNET_3_7: PricingTier = PricingTier {
    input_per_million: 3.0,
    output_per_million: 15.0,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

const HAIKU_3: PricingTier = PricingTier {
    input_per_million: 0.25,
    output_per_million: 1.25,
    cache_write_5m_multiplier: 1.25,
    cache_write_1h_multiplier: 2.0,
    cache_read_multiplier: 0.1,
};

// ─── Google ──────────────────────────────────────────────────────────────────

const GEMINI_PRO: PricingTier = PricingTier {
    input_per_million: 1.25,
    output_per_million: 5.0,
    cache_write_5m_multiplier: 1.0,
    cache_write_1h_multiplier: 1.0,
    cache_read_multiplier: 0.25,
};

const GEMINI_FLASH: PricingTier = PricingTier {
    input_per_million: 0.075,
    output_per_million: 0.3,
    cache_write_5m_multiplier: 1.0,
    cache_write_1h_multiplier: 1.0,
    cache_read_multiplier: 0.25,
};

// ─── `MiniMax` ─────────────────────────────────────────────────────────────────

const MINIMAX: PricingTier = PricingTier {
    input_per_million: 0.3,
    output_per_million: 1.2,
    cache_write_5m_multiplier: 1.0,
    cache_write_1h_multiplier: 1.0,
    cache_read_multiplier: 1.0,
};

/// Look up the pricing tier for a model.
///
/// Tries exact match first, then pattern-matches on model family substrings.
/// Returns `None` for unknown models (no implicit fallback pricing).
fn get_pricing_tier(model: &str) -> Option<&'static PricingTier> {
    use tron_llm::models::model_ids::{
        CLAUDE_3_7_SONNET, CLAUDE_3_HAIKU, CLAUDE_HAIKU_4_5, CLAUDE_OPUS_4, CLAUDE_OPUS_4_1,
        CLAUDE_OPUS_4_5, CLAUDE_OPUS_4_6, CLAUDE_SONNET_4, CLAUDE_SONNET_4_5, GEMINI_2_5_FLASH,
        GEMINI_2_5_PRO, GEMINI_3_FLASH_PREVIEW, GEMINI_3_PRO_PREVIEW, MINIMAX_M2,
        MINIMAX_M2_1, MINIMAX_M2_1_HIGHSPEED, MINIMAX_M2_5, MINIMAX_M2_5_HIGHSPEED,
    };

    // Exact match
    match model {
        CLAUDE_OPUS_4_6 => return Some(&OPUS_4_6),
        CLAUDE_OPUS_4_5 => return Some(&OPUS_4_5),
        CLAUDE_SONNET_4_5 => return Some(&SONNET_4_5),
        CLAUDE_HAIKU_4_5 => return Some(&HAIKU_4_5),
        CLAUDE_OPUS_4_1 => return Some(&OPUS_4_1),
        CLAUDE_OPUS_4 => return Some(&OPUS_4),
        CLAUDE_SONNET_4 => return Some(&SONNET_4),
        CLAUDE_3_7_SONNET => return Some(&SONNET_3_7),
        CLAUDE_3_HAIKU => return Some(&HAIKU_3),
        GEMINI_3_PRO_PREVIEW | GEMINI_2_5_PRO => return Some(&GEMINI_PRO),
        GEMINI_3_FLASH_PREVIEW | GEMINI_2_5_FLASH => return Some(&GEMINI_FLASH),
        MINIMAX_M2_5 | MINIMAX_M2_5_HIGHSPEED | MINIMAX_M2_1 | MINIMAX_M2_1_HIGHSPEED
        | MINIMAX_M2 => return Some(&MINIMAX),
        _ => {}
    }

    // Pattern matching on model family substrings
    let lower = model.to_lowercase();

    if lower.contains("minimax") {
        return Some(&MINIMAX);
    }
    if lower.contains("opus-4-6") || lower.contains("opus-4.6") {
        return Some(&OPUS_4_6);
    }
    if lower.contains("opus-4-5") || lower.contains("opus-4.5") {
        return Some(&OPUS_4_5);
    }
    if lower.contains("opus") {
        return Some(&OPUS_4);
    }
    if lower.contains("sonnet-4-5") || lower.contains("sonnet-4.5") {
        return Some(&SONNET_4_5);
    }
    if lower.contains("sonnet") {
        return Some(&SONNET_4);
    }
    if lower.contains("haiku-4-5") || lower.contains("haiku-4.5") {
        return Some(&HAIKU_4_5);
    }
    if lower.contains("haiku") {
        return Some(&HAIKU_3);
    }
    if lower.contains("gemini-2.5-pro") || lower.contains("gemini-3-pro") {
        return Some(&GEMINI_PRO);
    }
    if lower.contains("gemini") {
        return Some(&GEMINI_FLASH);
    }

    None
}

/// Calculate cost for a single API request.
///
/// Returns the total cost in USD, or `None` when pricing is unavailable.
pub fn calculate_cost(model: &str, usage: &TokenUsage) -> Option<f64> {
    let pricing = get_pricing_tier(model)?;

    #[allow(clippy::cast_precision_loss)]
    let input_tokens = usage.input_tokens as f64;
    #[allow(clippy::cast_precision_loss)]
    let output_tokens = usage.output_tokens as f64;
    #[allow(clippy::cast_precision_loss)]
    let cache_creation_tokens = usage.cache_creation_tokens.unwrap_or(0) as f64;
    #[allow(clippy::cast_precision_loss)]
    let cache_read_tokens = usage.cache_read_tokens.unwrap_or(0) as f64;
    #[allow(clippy::cast_precision_loss)]
    let cache_write_short = usage.cache_creation_5m_tokens.unwrap_or(0) as f64;
    #[allow(clippy::cast_precision_loss)]
    let cache_write_long = usage.cache_creation_1h_tokens.unwrap_or(0) as f64;

    // Base input tokens (excluding cache tokens billed separately)
    let base_input_tokens = (input_tokens - cache_read_tokens - cache_creation_tokens).max(0.0);
    let base_input_cost = (base_input_tokens / 1_000_000.0) * pricing.input_per_million;

    // Cache creation cost — use per-TTL pricing when breakdown is available
    let cache_creation_cost = if cache_write_short > 0.0 || cache_write_long > 0.0 {
        let short_cost = (cache_write_short / 1_000_000.0)
            * pricing.input_per_million
            * pricing.cache_write_5m_multiplier;
        let long_cost = (cache_write_long / 1_000_000.0)
            * pricing.input_per_million
            * pricing.cache_write_1h_multiplier;
        short_cost + long_cost
    } else {
        // Backward compat: fall back to 5m multiplier for total
        (cache_creation_tokens / 1_000_000.0)
            * pricing.input_per_million
            * pricing.cache_write_5m_multiplier
    };

    // Cache read cost (discounted rate)
    let cache_read_cost = (cache_read_tokens / 1_000_000.0)
        * pricing.input_per_million
        * pricing.cache_read_multiplier;

    let total_input_cost = base_input_cost + cache_creation_cost + cache_read_cost;

    // Output cost
    let output_cost = (output_tokens / 1_000_000.0) * pricing.output_per_million;

    Some(total_input_cost + output_cost)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tron_llm::models::model_ids::*;

    fn approx_eq(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    // ── Pricing tier lookup ──

    #[test]
    fn exact_match_opus_4_6() {
        let tier = get_pricing_tier(CLAUDE_OPUS_4_6).unwrap();
        assert!(approx_eq(tier.input_per_million, 5.0));
        assert!(approx_eq(tier.output_per_million, 25.0));
    }

    #[test]
    fn exact_match_sonnet_4_5() {
        let tier = get_pricing_tier(CLAUDE_SONNET_4_5).unwrap();
        assert!(approx_eq(tier.input_per_million, 3.0));
        assert!(approx_eq(tier.output_per_million, 15.0));
    }

    #[test]
    fn exact_match_haiku_4_5() {
        let tier = get_pricing_tier(CLAUDE_HAIKU_4_5).unwrap();
        assert!(approx_eq(tier.input_per_million, 1.0));
        assert!(approx_eq(tier.output_per_million, 5.0));
    }

    #[test]
    fn exact_match_haiku_3() {
        let tier = get_pricing_tier(CLAUDE_3_HAIKU).unwrap();
        assert!(approx_eq(tier.input_per_million, 0.25));
        assert!(approx_eq(tier.output_per_million, 1.25));
    }

    #[test]
    fn exact_match_gemini_pro() {
        let tier = get_pricing_tier(GEMINI_2_5_PRO).unwrap();
        assert!(approx_eq(tier.input_per_million, 1.25));
        assert!(approx_eq(tier.output_per_million, 5.0));
        assert!(approx_eq(tier.cache_read_multiplier, 0.25));
    }

    #[test]
    fn exact_match_gemini_flash() {
        let tier = get_pricing_tier(GEMINI_2_5_FLASH).unwrap();
        assert!(approx_eq(tier.input_per_million, 0.075));
        assert!(approx_eq(tier.output_per_million, 0.3));
    }

    #[test]
    fn pattern_match_opus_family() {
        let tier = get_pricing_tier("claude-opus-4-6-20260101").unwrap();
        assert!(approx_eq(tier.input_per_million, 5.0));
    }

    #[test]
    fn pattern_match_sonnet_family() {
        let tier = get_pricing_tier("claude-sonnet-4-5-beta").unwrap();
        assert!(approx_eq(tier.input_per_million, 3.0));
    }

    #[test]
    fn pattern_match_gemini_pro_family() {
        let tier = get_pricing_tier("gemini-2.5-pro-latest").unwrap();
        assert!(approx_eq(tier.input_per_million, 1.25));
    }

    #[test]
    fn unknown_model_has_no_pricing() {
        let tier = get_pricing_tier("totally-unknown-model");
        assert!(tier.is_none());
    }

    // ── Cost calculation ──

    #[test]
    fn basic_cost_no_cache() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_SONNET_4, &usage).unwrap();
        // 1M input * $3/M + 1M output * $15/M = $18
        assert!(approx_eq(cost, 18.0));
    }

    #[test]
    fn cost_with_cache_read() {
        let usage = TokenUsage {
            input_tokens: 100_000,
            output_tokens: 10_000,
            cache_read_tokens: Some(80_000),
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_OPUS_4_6, &usage).unwrap();
        // base_input = max(0, 100k - 80k - 0) = 20k
        // base_cost = (20k/1M) * 5 = 0.1
        // cache_read = (80k/1M) * 5 * 0.1 = 0.04
        // output = (10k/1M) * 25 = 0.25
        // total = 0.1 + 0.04 + 0.25 = 0.39
        assert!(approx_eq(cost, 0.39));
    }

    #[test]
    fn cost_with_cache_creation_fallback() {
        let usage = TokenUsage {
            input_tokens: 50_000,
            output_tokens: 5_000,
            cache_creation_tokens: Some(30_000),
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_SONNET_4_5, &usage).unwrap();
        // base_input = max(0, 50k - 0 - 30k) = 20k
        // base_cost = (20k/1M) * 3 = 0.06
        // cache_create = (30k/1M) * 3 * 1.25 = 0.1125
        // cache_read = 0
        // output = (5k/1M) * 15 = 0.075
        // total = 0.06 + 0.1125 + 0.075 = 0.2475
        assert!(approx_eq(cost, 0.2475));
    }

    #[test]
    fn cost_with_per_ttl_cache() {
        let usage = TokenUsage {
            input_tokens: 100_000,
            output_tokens: 10_000,
            cache_creation_tokens: Some(50_000),
            cache_creation_5m_tokens: Some(30_000),
            cache_creation_1h_tokens: Some(20_000),
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_OPUS_4_6, &usage).unwrap();
        // base_input = max(0, 100k - 0 - 50k) = 50k
        // base_cost = (50k/1M) * 5 = 0.25
        // cache_5m = (30k/1M) * 5 * 1.25 = 0.1875
        // cache_1h = (20k/1M) * 5 * 2.0 = 0.2
        // cache_create = 0.1875 + 0.2 = 0.3875
        // cache_read = 0
        // output = (10k/1M) * 25 = 0.25
        // total = 0.25 + 0.3875 + 0.25 = 0.8875
        assert!(approx_eq(cost, 0.8875));
    }

    #[test]
    fn cost_zero_tokens() {
        let usage = TokenUsage::default();
        let cost = calculate_cost(CLAUDE_OPUS_4_6, &usage).unwrap();
        assert!(approx_eq(cost, 0.0));
    }

    #[test]
    fn cost_gemini_no_cache_write_surcharge() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_creation_tokens: Some(500_000),
            ..Default::default()
        };
        let cost = calculate_cost(GEMINI_2_5_PRO, &usage).unwrap();
        // base_input = max(0, 1M - 0 - 500k) = 500k
        // base_cost = (500k/1M) * 1.25 = 0.625
        // cache_create = (500k/1M) * 1.25 * 1.0 = 0.625 (multiplier=1.0)
        // output = (1M/1M) * 5 = 5
        // total = 0.625 + 0.625 + 5 = 6.25
        assert!(approx_eq(cost, 6.25));
    }

    #[test]
    fn cost_haiku_cheap() {
        let usage = TokenUsage {
            input_tokens: 10_000,
            output_tokens: 5_000,
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_3_HAIKU, &usage).unwrap();
        // (10k/1M) * 0.25 + (5k/1M) * 1.25 = 0.0025 + 0.00625 = 0.00875
        assert!(approx_eq(cost, 0.00875));
    }

    #[test]
    fn cost_typical_turn() {
        // A realistic turn: ~10k input (mostly cache read), 500 output
        let usage = TokenUsage {
            input_tokens: 500,
            output_tokens: 500,
            cache_read_tokens: Some(9500),
            cache_creation_tokens: Some(200),
            ..Default::default()
        };
        let cost = calculate_cost(CLAUDE_SONNET_4, &usage).unwrap();
        // base_input = max(0, 500 - 9500 - 200) = 0 (clamped)
        // base_cost = 0
        // cache_create = (200/1M) * 3 * 1.25 = 0.00075
        // cache_read = (9500/1M) * 3 * 0.1 = 0.00285
        // output = (500/1M) * 15 = 0.0075
        // total = 0 + 0.00075 + 0.00285 + 0.0075 = 0.0111
        assert!(approx_eq(cost, 0.0111));
    }

    #[test]
    fn exact_match_minimax() {
        let tier = get_pricing_tier(MINIMAX_M2_5).unwrap();
        assert!(approx_eq(tier.input_per_million, 0.3));
        assert!(approx_eq(tier.output_per_million, 1.2));
    }

    #[test]
    fn exact_match_minimax_all_models() {
        for id in [
            MINIMAX_M2_5,
            MINIMAX_M2_5_HIGHSPEED,
            MINIMAX_M2_1,
            MINIMAX_M2_1_HIGHSPEED,
            MINIMAX_M2,
        ] {
            assert!(
                get_pricing_tier(id).is_some(),
                "missing pricing for {id}"
            );
        }
    }

    #[test]
    fn pattern_match_minimax() {
        let tier = get_pricing_tier("minimax-future-model").unwrap();
        assert!(approx_eq(tier.input_per_million, 0.3));
    }

    #[test]
    fn cost_minimax_no_cache_surcharge() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_creation_tokens: Some(500_000),
            ..Default::default()
        };
        let cost = calculate_cost(MINIMAX_M2_5, &usage).unwrap();
        // base_input = max(0, 1M - 0 - 500k) = 500k
        // base_cost = (500k/1M) * 0.3 = 0.15
        // cache_create = (500k/1M) * 0.3 * 1.0 = 0.15 (multiplier=1.0)
        // output = (1M/1M) * 1.2 = 1.2
        // total = 0.15 + 0.15 + 1.2 = 1.5
        assert!(approx_eq(cost, 1.5));
    }

    #[test]
    fn cost_unknown_model_returns_none() {
        let usage = TokenUsage {
            input_tokens: 1000,
            output_tokens: 1000,
            ..Default::default()
        };
        assert!(calculate_cost("totally-unknown-model", &usage).is_none());
    }
}
