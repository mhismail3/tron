//! Cost estimation from token counts and model ID.
//!
//! Uses published Anthropic pricing to estimate USD cost from a
//! [`ClaudeUsage`] record and a model identifier string.

use crate::import::types::ClaudeUsage;

/// Per-million-token pricing for a model.
struct Pricing {
    input: f64,
    output: f64,
    cache_read: f64,
    cache_write: f64,
}

/// Return pricing for a known model, or `None` for unknown models.
fn pricing(model: &str) -> Option<Pricing> {
    match model {
        // Opus tier ($15/$75 per MTok)
        "claude-opus-4-6"
        | "claude-opus-4-20250514"
        | "claude-opus-4-6-20250609"
        | "claude-3-opus-20240229" => Some(Pricing {
            input: 15.0,
            output: 75.0,
            cache_read: 1.5,
            cache_write: 18.75,
        }),
        // Sonnet tier ($3/$15 per MTok)
        "claude-sonnet-4-6"
        | "claude-sonnet-4-20250514"
        | "claude-sonnet-4-6-20250514"
        | "claude-3-5-sonnet-20241022"
        | "claude-3-5-sonnet-20240620" => Some(Pricing {
            input: 3.0,
            output: 15.0,
            cache_read: 0.30,
            cache_write: 3.75,
        }),
        // Haiku tier ($0.80/$4 per MTok)
        "claude-haiku-4-5-20251001"
        | "claude-3-5-haiku-20241022" => Some(Pricing {
            input: 0.80,
            output: 4.0,
            cache_read: 0.08,
            cache_write: 1.0,
        }),
        _ => None,
    }
}

/// Estimate USD cost from token counts and model ID.
///
/// Returns 0.0 for unknown models or zero tokens.
pub fn estimate_cost(model: &str, usage: &ClaudeUsage) -> f64 {
    let Some(p) = pricing(model) else {
        return 0.0;
    };

    let input = usage.input_tokens as f64 * p.input / 1_000_000.0;
    let output = usage.output_tokens as f64 * p.output / 1_000_000.0;
    let cache_read = usage.cache_read_input_tokens as f64 * p.cache_read / 1_000_000.0;
    let cache_write = usage.cache_creation_input_tokens as f64 * p.cache_write / 1_000_000.0;

    input + output + cache_read + cache_write
}

#[cfg(test)]
#[path = "cost_tests.rs"]
mod tests;
