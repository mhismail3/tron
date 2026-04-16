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
    // $15 input + $75 output = $90
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
    // $1.50 cache_read + $18.75 cache_write = $20.25
    assert!((cost - 20.25).abs() < 0.001);
}

#[test]
fn model_alias_resolution() {
    let u = usage(1_000_000, 0);
    let cost1 = estimate_cost("claude-opus-4-6", &u);
    let cost2 = estimate_cost("claude-opus-4-20250514", &u);
    assert_eq!(cost1, cost2);
}

#[test]
fn sonnet_35_v2_cost() {
    let cost = estimate_cost("claude-3-5-sonnet-20241022", &usage(1_000_000, 1_000_000));
    // Same as Sonnet 4: $3 + $15 = $18
    assert!((cost - 18.0).abs() < 0.001);
}
