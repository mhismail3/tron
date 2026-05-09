use super::*;

fn usage(input: i64, output: i64) -> ClaudeUsage {
    ClaudeUsage {
        input_tokens: input,
        output_tokens: output,
        cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0,
    }
}

#[test]
fn opus_cost() {
    let cost = estimate_cost("claude-opus-4-6", &usage(1_000_000, 1_000_000));
    // $5 input + $25 output = $30 (Opus 4.6+ tier)
    assert!((cost - 30.0).abs() < 0.001);
}

#[test]
fn opus_4_7_cost() {
    let cost = estimate_cost("claude-opus-4-7", &usage(1_000_000, 1_000_000));
    // Opus 4.7 is priced the same as 4.6: $5 input + $25 output = $30
    assert!((cost - 30.0).abs() < 0.001);
}

#[test]
fn opus_3_cost() {
    let cost = estimate_cost("claude-opus-4-20250514", &usage(1_000_000, 1_000_000));
    // Opus 3 pricing tier: $15 input + $75 output = $90
    assert!((cost - 90.0).abs() < 0.001);
}

#[test]
fn sonnet_cost() {
    let cost = estimate_cost("claude-sonnet-4-6", &usage(1_000_000, 1_000_000));
    // $3 input + $15 output = $18
    assert!((cost - 18.0).abs() < 0.001);
}

#[test]
fn haiku_cost() {
    let cost = estimate_cost("claude-haiku-4-5-20251001", &usage(1_000_000, 1_000_000));
    // $0.80 input + $4 output = $4.80
    assert!((cost - 4.80).abs() < 0.001);
}

#[test]
fn unknown_model_returns_zero() {
    let cost = estimate_cost("gpt-4o", &usage(1_000_000, 1_000_000));
    assert_eq!(cost, 0.0);
}

#[test]
fn zero_tokens_returns_zero() {
    let cost = estimate_cost("claude-opus-4-6", &usage(0, 0));
    assert_eq!(cost, 0.0);
}

#[test]
fn cache_tokens_included() {
    let u = ClaudeUsage {
        input_tokens: 0,
        output_tokens: 0,
        cache_read_input_tokens: 1_000_000,
        cache_creation_input_tokens: 1_000_000,
    };
    let cost = estimate_cost("claude-opus-4-6", &u);
    // Opus 4.6+ tier: $0.50 cache_read + $6.25 cache_write = $6.75
    assert!((cost - 6.75).abs() < 0.001);
}

#[test]
fn model_alias_resolution() {
    // Opus 4.7 and 4.6 share the same tier pricing.
    let u = usage(1_000_000, 0);
    let cost1 = estimate_cost("claude-opus-4-7", &u);
    let cost2 = estimate_cost("claude-opus-4-6", &u);
    assert_eq!(cost1, cost2);
}

#[test]
fn sonnet_35_v2_cost() {
    let cost = estimate_cost("claude-3-5-sonnet-20241022", &usage(1_000_000, 1_000_000));
    // Same as Sonnet 4: $3 + $15 = $18
    assert!((cost - 18.0).abs() < 0.001);
}
