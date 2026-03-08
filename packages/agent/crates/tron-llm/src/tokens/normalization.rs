//! Token normalization — provider-aware context window calculation.
//!
//! Different providers report `input_tokens` differently:
//!
//! | Provider | `input_tokens` means | Context window formula |
//! |----------|---------------------|------------------------|
//! | Anthropic | **New** tokens only | `input + cache_read + cache_creation` |
//! | `OpenAI` / Google | Full context sent | `input_tokens` directly |
//!
//! This module normalizes provider data into a uniform [`TokenRecord`]
//! with correct context window size and per-turn deltas.

use tron_core::messages::Provider;

use super::types::{CalculationMethod, ComputedTokens, TokenMeta, TokenRecord, TokenSource};

/// Normalize raw token data into a [`TokenRecord`].
///
/// Takes the raw provider data, the previous context window baseline
/// (from the prior turn), and metadata. Returns an immutable record
/// with computed context window size and per-turn delta.
pub fn normalize_tokens(
    source: TokenSource,
    previous_baseline: u64,
    meta: TokenMeta,
) -> TokenRecord {
    let (context_window_tokens, calculation_method) = compute_context_window(&source);
    let new_input_tokens =
        compute_new_input_tokens(&source, context_window_tokens, previous_baseline);

    let computed = ComputedTokens {
        context_window_tokens,
        new_input_tokens,
        previous_context_baseline: previous_baseline,
        calculation_method,
    };

    let mut meta = meta;
    meta.normalized_at = chrono::Utc::now().to_rfc3339();

    TokenRecord {
        source,
        computed,
        meta,
    }
}

/// Compute context window size based on provider type.
///
/// Anthropic reports `input`/`cache_read`/`cache_creation` as three mutually
/// exclusive buckets. Other providers report the full context in `input_tokens`.
fn compute_context_window(source: &TokenSource) -> (u64, CalculationMethod) {
    match source.provider {
        Provider::Anthropic | Provider::MiniMax => {
            let total = source.raw_input_tokens
                + source.raw_cache_read_tokens
                + source.raw_cache_creation_tokens;
            (total, CalculationMethod::AnthropicCacheAware)
        }
        Provider::OpenAi
        | Provider::OpenAiCodex
        | Provider::Google
        | Provider::Unknown => (source.raw_input_tokens, CalculationMethod::Direct),
    }
}

/// Compute per-turn delta (new tokens added this turn).
///
/// For Anthropic/MiniMax: `raw_input + cache_creation` — uncached tokens plus
/// tokens newly written to cache this turn. Cache *reads* are pre-existing
/// context, not new content.
/// For other providers: use context window delta (no cache semantics).
fn compute_new_input_tokens(
    source: &TokenSource,
    context_window_tokens: u64,
    previous_baseline: u64,
) -> u64 {
    if matches!(source.provider, Provider::Anthropic | Provider::MiniMax) {
        source.raw_input_tokens + source.raw_cache_creation_tokens
    } else {
        if previous_baseline == 0 {
            return context_window_tokens;
        }
        context_window_tokens.saturating_sub(previous_baseline)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_meta(turn: u64) -> TokenMeta {
        TokenMeta {
            turn,
            session_id: "sess_test".to_string(),
            extracted_at: "2024-01-15T12:00:00Z".to_string(),
            normalized_at: String::new(),
        }
    }

    fn anthropic_source(input: u64, cache_read: u64, cache_creation: u64) -> TokenSource {
        TokenSource {
            provider: Provider::Anthropic,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            raw_input_tokens: input,
            raw_output_tokens: 100,
            raw_cache_read_tokens: cache_read,
            raw_cache_creation_tokens: cache_creation,
            raw_cache_creation_5m_tokens: 0,
            raw_cache_creation_1h_tokens: 0,
        }
    }

    fn google_source(input: u64) -> TokenSource {
        TokenSource {
            provider: Provider::Google,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            raw_input_tokens: input,
            raw_output_tokens: 50,
            raw_cache_read_tokens: 0,
            raw_cache_creation_tokens: 0,
            raw_cache_creation_5m_tokens: 0,
            raw_cache_creation_1h_tokens: 0,
        }
    }

    // ── Context window calculation ──

    #[test]
    fn anthropic_context_window_adds_cache() {
        let source = anthropic_source(604, 8266, 0);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.context_window_tokens, 604 + 8266);
        assert_eq!(
            record.computed.calculation_method,
            CalculationMethod::AnthropicCacheAware
        );
    }

    #[test]
    fn anthropic_context_window_all_three_buckets() {
        let source = anthropic_source(100, 500, 200);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.context_window_tokens, 100 + 500 + 200);
    }

    #[test]
    fn google_context_window_direct() {
        let source = google_source(5000);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.context_window_tokens, 5000);
        assert_eq!(
            record.computed.calculation_method,
            CalculationMethod::Direct
        );
    }

    #[test]
    fn openai_context_window_direct() {
        let source = TokenSource {
            provider: Provider::OpenAi,
            timestamp: "2024-01-15T12:00:00Z".to_string(),
            raw_input_tokens: 10_000,
            raw_output_tokens: 500,
            raw_cache_read_tokens: 8000,
            raw_cache_creation_tokens: 0,
            raw_cache_creation_5m_tokens: 0,
            raw_cache_creation_1h_tokens: 0,
        };
        let record = normalize_tokens(source, 0, make_meta(1));
        // OpenAI input_tokens already includes full context
        assert_eq!(record.computed.context_window_tokens, 10_000);
        assert_eq!(
            record.computed.calculation_method,
            CalculationMethod::Direct
        );
    }

    // ── Per-turn delta calculation ──

    // ── Anthropic: newInputTokens = rawInput + cacheCreation (non-cached-read) ──

    #[test]
    fn anthropic_first_turn_cache_hit_new_input_excludes_cache_read() {
        // rawInput=604, cacheRead=8266 → newInput = 604 (cache read is pre-existing)
        let source = anthropic_source(604, 8266, 0);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.new_input_tokens, 604);
        assert_eq!(record.computed.context_window_tokens, 604 + 8266);
        assert_eq!(record.computed.previous_context_baseline, 0);
    }

    #[test]
    fn anthropic_second_turn_cache_hit_new_input_excludes_cache_read() {
        let source = anthropic_source(604, 8266, 0);
        let record = normalize_tokens(source, 8768, make_meta(2));
        assert_eq!(record.computed.context_window_tokens, 8870);
        assert_eq!(record.computed.new_input_tokens, 604);
        assert_eq!(record.computed.previous_context_baseline, 8768);
    }

    #[test]
    fn anthropic_cache_creation_counts_as_new_input() {
        // rawInput=100, cacheRead=500, cacheCreation=200
        // New content = 100 + 200 = 300 (cache reads are pre-existing)
        let source = anthropic_source(100, 500, 200);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.new_input_tokens, 300);
    }

    // ── Google/OpenAI: delta-based (no cache semantics) ──

    #[test]
    fn google_first_turn_new_input_is_full_context() {
        let source = google_source(5000);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.computed.new_input_tokens, 5000);
    }

    #[test]
    fn google_second_turn_new_input_is_delta() {
        let source = google_source(5500);
        let record = normalize_tokens(source, 5000, make_meta(2));
        assert_eq!(record.computed.new_input_tokens, 500);
    }

    #[test]
    fn context_shrank_delta_zero() {
        let source = google_source(5000);
        let record = normalize_tokens(source, 10_000, make_meta(3));
        assert_eq!(record.computed.new_input_tokens, 0);
    }

    #[test]
    fn context_unchanged_delta_zero() {
        let source = google_source(5000);
        let record = normalize_tokens(source, 5000, make_meta(2));
        assert_eq!(record.computed.new_input_tokens, 0);
    }

    // ── Metadata ──

    #[test]
    fn normalized_at_is_set() {
        let source = google_source(100);
        let record = normalize_tokens(source, 0, make_meta(1));
        assert!(!record.meta.normalized_at.is_empty());
        assert_ne!(record.meta.normalized_at, "");
    }

    #[test]
    fn source_preserved_unchanged() {
        let source = anthropic_source(604, 8266, 0);
        let original = source.clone();
        let record = normalize_tokens(source, 0, make_meta(1));
        assert_eq!(record.source, original);
    }
}
