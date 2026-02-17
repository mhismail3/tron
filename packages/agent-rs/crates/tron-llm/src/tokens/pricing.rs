//! Model pricing tables and cost calculation.
//!
//! Pricing data is organized by provider family. Cost calculation handles
//! Anthropic's per-TTL cache pricing (5-minute and 1-hour tiers), Google's
//! flat pricing, and `OpenAI`'s model-registry pricing.

use tron_core::messages::{Cost, TokenUsage};

use super::types::PricingTier;

/// Look up the pricing tier for a model identifier.
///
/// Uses exact-match first, then prefix/pattern matching, then falls back
/// to Claude Sonnet 4.5 pricing as the default.
#[must_use]
pub fn get_pricing_tier(model: &str) -> PricingTier {
    // Exact match first
    if let Some(tier) = exact_match(model) {
        return tier;
    }

    // Pattern match (prefix-based)
    if let Some(tier) = pattern_match(model) {
        return tier;
    }

    // Default: Sonnet 4.5
    anthropic_tier(3.0, 15.0)
}

/// Calculate cost for a given model and token usage.
///
/// Returns a [`Cost`] with separate input/output costs and total.
/// Handles Anthropic per-TTL cache tiers (5-minute @ 1.25x, 1-hour @ 2.0x)
/// and standard cache pricing for other providers.
#[must_use]
#[allow(clippy::cast_precision_loss)] // Token counts never approach 2^52
pub fn calculate_cost(model: &str, usage: &TokenUsage) -> Cost {
    let tier = get_pricing_tier(model);

    let input = usage.input_tokens;
    let output = usage.output_tokens;
    let cache_read = usage.cache_read_tokens.unwrap_or(0);
    let cache_creation = usage.cache_creation_tokens.unwrap_or(0);
    let cache_5min = usage.cache_creation_5m_tokens.unwrap_or(0);
    let cache_1hr = usage.cache_creation_1h_tokens.unwrap_or(0);

    // Base input tokens = total input minus cache components
    let base_input = input.saturating_sub(cache_read).saturating_sub(cache_creation);
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

    Cost {
        input_cost,
        output_cost,
        total,
        currency: "USD".to_string(),
    }
}

/// Format a cost value for display.
///
/// Uses 3 decimal places for values under $0.01, 2 otherwise.
#[must_use]
pub fn format_cost(cost: f64) -> String {
    if cost < 0.01 {
        format!("${cost:.3}")
    } else {
        format!("${cost:.2}")
    }
}

/// Format a token count for display (e.g., `"1.5M"`, `"50K"`, `"500"`).
#[must_use]
#[allow(clippy::cast_precision_loss)] // Token counts never approach 2^52
pub fn format_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        let m = n as f64 / 1_000_000.0;
        if (m - m.round()).abs() < 0.05 {
            format!("{m:.0}M")
        } else {
            format!("{m:.1}M")
        }
    } else if n >= 1_000 {
        let k = n as f64 / 1_000.0;
        if (k - k.round()).abs() < 0.05 {
            format!("{k:.0}K")
        } else {
            format!("{k:.1}K")
        }
    } else {
        n.to_string()
    }
}

/// Detect provider type from a model identifier string.
#[must_use]
pub fn detect_provider(model: &str) -> tron_core::messages::ProviderType {
    use tron_core::messages::ProviderType;
    let m = model.to_lowercase();
    if m.contains("claude") {
        ProviderType::Anthropic
    } else if m.contains("codex")
        || m.starts_with("o1")
        || m.starts_with("o3")
        || m.starts_with("o4")
    {
        ProviderType::OpenAiCodex
    } else if m.contains("gpt") || m.contains("openai/") {
        ProviderType::OpenAi
    } else if m.contains("gemini") || m.contains("google/") {
        ProviderType::Google
    } else {
        // Default to Anthropic
        ProviderType::Anthropic
    }
}

/// Get the default context window limit for a model.
#[must_use]
pub fn get_context_limit(model: &str) -> u64 {
    let m = model.to_lowercase();
    if m.contains("claude") {
        200_000
    } else if m.contains("gemini") {
        1_048_576
    } else if m.starts_with("o1") || m.starts_with("o3") || m.starts_with("o4") {
        200_000
    } else if m.contains("gpt-4") {
        128_000
    } else {
        200_000
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

/// Create an `OpenAI` pricing tier (no separate cache write cost).
fn openai_tier(input: f64, output: f64) -> PricingTier {
    PricingTier {
        input_per_million: input,
        output_per_million: output,
        cache_write_5m_multiplier: 1.0,
        cache_write_1h_multiplier: 1.0,
        cache_read_multiplier: 0.5,
    }
}

/// Exact model name matching.
fn exact_match(model: &str) -> Option<PricingTier> {
    Some(match model {
        // Anthropic — Opus 4.5/4.6
        "claude-opus-4-6" | "claude-opus-4-5" => anthropic_tier(5.0, 25.0),

        // Anthropic — Sonnet family ($3/$15)
        "claude-sonnet-4-5-20250929" | "claude-sonnet-4-5"
        | "claude-sonnet-4-0-20250514" | "claude-sonnet-4"
        | "claude-3-7-sonnet-20250219" | "claude-3-7-sonnet" => anthropic_tier(3.0, 15.0),

        // Anthropic — Haiku 4.5
        "claude-haiku-4-5-20251001" | "claude-haiku-4-5" => anthropic_tier(1.0, 5.0),

        // Anthropic — Opus 4/4.1 ($15/$75)
        "claude-opus-4-1-20250415" | "claude-opus-4-1" | "claude-opus-4-0-20250415"
        | "claude-opus-4" => anthropic_tier(15.0, 75.0),

        // Anthropic — Claude 3 Haiku
        "claude-3-haiku-20240307" | "claude-3-haiku" => anthropic_tier(0.25, 1.25),

        // Google — Gemini Pro
        "gemini-3-pro-preview" | "gemini-2-5-pro" | "gemini-2.5-pro" => google_tier(1.25, 5.0),

        // Google — Gemini Flash
        "gemini-3-flash-preview" | "gemini-2-5-flash" | "gemini-2.5-flash" => {
            google_tier(0.075, 0.3)
        }

        // OpenAI
        "o3" | "o3-2025-04-16" => openai_tier(10.0, 40.0),
        "o4-mini" | "o4-mini-2025-04-16" => openai_tier(1.10, 4.40),
        "gpt-4.1" | "gpt-4.1-2025-04-14" => openai_tier(2.0, 8.0),
        "gpt-4.1-mini" | "gpt-4.1-mini-2025-04-14" => openai_tier(0.40, 1.60),
        "gpt-4.1-nano" | "gpt-4.1-nano-2025-04-14" => openai_tier(0.10, 0.40),

        _ => return None,
    })
}

/// Prefix/pattern-based matching for model families.
fn pattern_match(model: &str) -> Option<PricingTier> {
    let m = model.to_lowercase();

    // Claude family patterns
    if m.contains("opus-4-6") || m.contains("opus-4-5") {
        return Some(anthropic_tier(5.0, 25.0));
    }
    if m.contains("sonnet-4-5") || m.contains("sonnet-4") || m.contains("sonnet-3-7") {
        return Some(anthropic_tier(3.0, 15.0));
    }
    if m.contains("haiku-4-5") {
        return Some(anthropic_tier(1.0, 5.0));
    }
    if m.contains("opus-4-1") || m.contains("opus-4") {
        return Some(anthropic_tier(15.0, 75.0));
    }
    if m.contains("haiku-3") {
        return Some(anthropic_tier(0.25, 1.25));
    }

    // Gemini family patterns
    if m.contains("gemini") && m.contains("pro") {
        return Some(google_tier(1.25, 5.0));
    }
    if m.contains("gemini") && m.contains("flash") {
        return Some(google_tier(0.075, 0.3));
    }

    // OpenAI patterns
    if m.starts_with("o3") {
        return Some(openai_tier(10.0, 40.0));
    }
    if m.starts_with("o4") {
        return Some(openai_tier(1.10, 4.40));
    }
    if m.contains("gpt-4.1-nano") {
        return Some(openai_tier(0.10, 0.40));
    }
    if m.contains("gpt-4.1-mini") {
        return Some(openai_tier(0.40, 1.60));
    }
    if m.contains("gpt-4.1") {
        return Some(openai_tier(2.0, 8.0));
    }

    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::messages::ProviderType;

    // ── Pricing tier lookup ──

    #[test]
    fn pricing_claude_opus_46() {
        let tier = get_pricing_tier("claude-opus-4-6");
        assert_eq!(tier.input_per_million, 5.0);
        assert_eq!(tier.output_per_million, 25.0);
        assert_eq!(tier.cache_write_5m_multiplier, 1.25);
        assert_eq!(tier.cache_write_1h_multiplier, 2.0);
        assert_eq!(tier.cache_read_multiplier, 0.1);
    }

    #[test]
    fn pricing_claude_sonnet_45() {
        let tier = get_pricing_tier("claude-sonnet-4-5-20250929");
        assert_eq!(tier.input_per_million, 3.0);
        assert_eq!(tier.output_per_million, 15.0);
    }

    #[test]
    fn pricing_claude_haiku_45() {
        let tier = get_pricing_tier("claude-haiku-4-5-20251001");
        assert_eq!(tier.input_per_million, 1.0);
        assert_eq!(tier.output_per_million, 5.0);
    }

    #[test]
    fn pricing_claude_opus_41() {
        let tier = get_pricing_tier("claude-opus-4-1");
        assert_eq!(tier.input_per_million, 15.0);
        assert_eq!(tier.output_per_million, 75.0);
    }

    #[test]
    fn pricing_claude_3_haiku() {
        let tier = get_pricing_tier("claude-3-haiku");
        assert_eq!(tier.input_per_million, 0.25);
        assert_eq!(tier.output_per_million, 1.25);
    }

    #[test]
    fn pricing_gemini_pro() {
        let tier = get_pricing_tier("gemini-3-pro-preview");
        assert_eq!(tier.input_per_million, 1.25);
        assert_eq!(tier.output_per_million, 5.0);
        assert_eq!(tier.cache_read_multiplier, 0.25);
    }

    #[test]
    fn pricing_gemini_flash() {
        let tier = get_pricing_tier("gemini-2-5-flash");
        assert_eq!(tier.input_per_million, 0.075);
        assert_eq!(tier.output_per_million, 0.3);
    }

    #[test]
    fn pricing_o3() {
        let tier = get_pricing_tier("o3");
        assert_eq!(tier.input_per_million, 10.0);
        assert_eq!(tier.output_per_million, 40.0);
    }

    #[test]
    fn pricing_unknown_defaults_to_sonnet() {
        let tier = get_pricing_tier("some-unknown-model");
        assert_eq!(tier.input_per_million, 3.0);
        assert_eq!(tier.output_per_million, 15.0);
    }

    #[test]
    fn pricing_pattern_match_partial_names() {
        // Should match via pattern
        let tier = get_pricing_tier("claude-opus-4-6-extended");
        assert_eq!(tier.input_per_million, 5.0);

        let tier = get_pricing_tier("gemini-2-5-pro-latest");
        assert_eq!(tier.input_per_million, 1.25);
    }

    // ── Cost calculation ──

    #[test]
    fn cost_simple_no_cache() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 100_000,
            ..Default::default()
        };
        let cost = calculate_cost("claude-sonnet-4-5", &usage);
        assert!((cost.input_cost - 3.0).abs() < 0.001); // 1M * $3/M
        assert!((cost.output_cost - 1.5).abs() < 0.001); // 100K * $15/M
        assert!((cost.total - 4.5).abs() < 0.001);
        assert_eq!(cost.currency, "USD");
    }

    #[test]
    fn cost_with_cache_aggregate() {
        let usage = TokenUsage {
            input_tokens: 1_000_000,
            output_tokens: 100_000,
            cache_read_tokens: Some(800_000),
            cache_creation_tokens: Some(100_000),
            ..Default::default()
        };
        let cost = calculate_cost("claude-sonnet-4-5", &usage);

        // base = 1M - 800K - 100K = 100K @ $3/M = $0.30
        // cache creation = 100K @ $3/M * 1.25 = $0.375
        // cache read = 800K @ $3/M * 0.1 = $0.24
        // output = 100K @ $15/M = $1.50
        let expected_input = 0.30 + 0.375 + 0.24;
        assert!((cost.input_cost - expected_input).abs() < 0.001);
        assert!((cost.output_cost - 1.5).abs() < 0.001);
    }

    #[test]
    fn cost_with_per_ttl_cache() {
        let usage = TokenUsage {
            input_tokens: 500_000,
            output_tokens: 50_000,
            cache_read_tokens: Some(0),
            cache_creation_tokens: Some(200_000),
            cache_creation_5m_tokens: Some(100_000),
            cache_creation_1h_tokens: Some(100_000),
            ..Default::default()
        };
        let cost = calculate_cost("claude-opus-4-6", &usage);

        // Per-TTL takes precedence over aggregate
        // 5m: 100K @ $5/M * 1.25 = $0.625
        // 1h: 100K @ $5/M * 2.0 = $1.00
        // cache creation total = $1.625
        // base = 500K - 0 - 200K = 300K @ $5/M = $1.50
        // cache read = 0
        // output = 50K @ $25/M = $1.25
        let expected_input = 1.50 + 0.625 + 1.00;
        assert!((cost.input_cost - expected_input).abs() < 0.001);
        assert!((cost.output_cost - 1.25).abs() < 0.001);
    }

    #[test]
    fn cost_zero_usage() {
        let usage = TokenUsage::default();
        let cost = calculate_cost("claude-opus-4-6", &usage);
        assert_eq!(cost.total, 0.0);
    }

    #[test]
    fn cost_base_input_saturates_to_zero() {
        // When cache read + creation > input, base should not go negative
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 0,
            cache_read_tokens: Some(200),
            cache_creation_tokens: Some(200),
            ..Default::default()
        };
        let cost = calculate_cost("claude-sonnet-4-5", &usage);
        // Base input saturates to 0, but cache costs are still counted
        assert!(cost.input_cost >= 0.0);
        assert!(cost.total >= 0.0);
    }

    // ── Format utilities ──

    #[test]
    fn format_cost_small() {
        assert_eq!(format_cost(0.005), "$0.005");
        assert_eq!(format_cost(0.001), "$0.001");
    }

    #[test]
    fn format_cost_normal() {
        assert_eq!(format_cost(1.50), "$1.50");
        assert_eq!(format_cost(5.00), "$5.00");
        assert_eq!(format_cost(0.01), "$0.01");
    }

    #[test]
    fn format_cost_zero() {
        assert_eq!(format_cost(0.0), "$0.000");
    }

    #[test]
    fn format_tokens_millions() {
        assert_eq!(format_tokens(1_500_000), "1.5M");
        assert_eq!(format_tokens(2_000_000), "2M");
    }

    #[test]
    fn format_tokens_thousands() {
        assert_eq!(format_tokens(50_000), "50K");
        assert_eq!(format_tokens(1_500), "1.5K");
    }

    #[test]
    fn format_tokens_small() {
        assert_eq!(format_tokens(500), "500");
        assert_eq!(format_tokens(0), "0");
    }

    // ── Provider detection ──

    #[test]
    fn detect_anthropic() {
        assert_eq!(detect_provider("claude-opus-4-6"), ProviderType::Anthropic);
        assert_eq!(
            detect_provider("claude-sonnet-4-5-20250929"),
            ProviderType::Anthropic
        );
    }

    #[test]
    fn detect_google() {
        assert_eq!(
            detect_provider("gemini-2-5-pro"),
            ProviderType::Google
        );
    }

    #[test]
    fn detect_openai() {
        assert_eq!(detect_provider("gpt-4.1"), ProviderType::OpenAi);
    }

    #[test]
    fn detect_openai_codex() {
        assert_eq!(detect_provider("o3"), ProviderType::OpenAiCodex);
        assert_eq!(detect_provider("o4-mini"), ProviderType::OpenAiCodex);
    }

    #[test]
    fn detect_unknown_defaults_to_anthropic() {
        assert_eq!(
            detect_provider("some-unknown-model"),
            ProviderType::Anthropic
        );
    }

    // ── Context limit ──

    #[test]
    fn context_limit_claude() {
        assert_eq!(get_context_limit("claude-opus-4-6"), 200_000);
    }

    #[test]
    fn context_limit_gemini() {
        assert_eq!(get_context_limit("gemini-2-5-pro"), 1_048_576);
    }

    #[test]
    fn context_limit_gpt4() {
        assert_eq!(get_context_limit("gpt-4-turbo"), 128_000);
    }

    #[test]
    fn context_limit_unknown() {
        assert_eq!(get_context_limit("unknown"), 200_000);
    }
}
