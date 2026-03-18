//! # Model Registry
//!
//! Unified model registry for provider detection, model lookup, and capability queries.
//! Each provider maintains its own detailed model registry (pricing, capabilities, etc.)
//! in its respective module. This module provides cross-provider utilities.
//!
//! **Single source of truth**: provider type files (`anthropic/types.rs`, etc.) own all
//! model metadata. This module derives lookups from those registries — no static arrays.

use crate::llm::anthropic::types::{all_claude_model_ids, get_claude_model};
use crate::llm::google::types::{all_gemini_model_ids, get_gemini_model};
use crate::llm::minimax::types::{all_minimax_model_ids, get_minimax_model};
use crate::llm::openai::types::{all_openai_model_ids, get_openai_model};
use crate::core::messages::Provider;

/// Detect which provider serves a given model ID.
///
/// Resolution order:
/// 1. Explicit prefix (e.g., `"openai/gpt-5"` → `OpenAi`)
/// 2. Registry lookup (exact match in provider HashMap — O(1))
///
/// Unknown model IDs always return `None` (strict fail-fast behavior).
pub fn detect_provider_from_model(model_id: &str) -> Option<Provider> {
    // 1. Explicit prefix: "provider/model". Prefix is accepted only when the
    // bare model exists in that provider's registry.
    if let Some((prefix, bare_model)) = model_id.split_once('/') {
        return match prefix {
            "anthropic" if get_claude_model(bare_model).is_some() => Some(Provider::Anthropic),
            "openai" | "openai-codex" if get_openai_model(bare_model).is_some() => {
                Some(Provider::OpenAi)
            }
            "google" | "gemini" if get_gemini_model(bare_model).is_some() => {
                Some(Provider::Google)
            }
            "minimax" if get_minimax_model(bare_model).is_some() => Some(Provider::MiniMax),
            _ => None,
        };
    }

    // 2. Registry lookup (O(1) HashMap lookups)
    if get_claude_model(model_id).is_some() {
        return Some(Provider::Anthropic);
    }
    if get_openai_model(model_id).is_some() {
        return Some(Provider::OpenAi);
    }
    if get_gemini_model(model_id).is_some() {
        return Some(Provider::Google);
    }
    if get_minimax_model(model_id).is_some() {
        return Some(Provider::MiniMax);
    }

    // Unknown model.
    None
}

/// Strip the explicit provider prefix from a model ID, if present.
///
/// `"openai/gpt-5.3-codex"` → `"gpt-5.3-codex"`
/// `"claude-opus-4-6"` → `"claude-opus-4-6"` (unchanged)
pub fn strip_provider_prefix(model_id: &str) -> &str {
    model_id
        .split_once('/')
        .map_or(model_id, |(_, model)| model)
}

/// Check if a model ID is recognized by any provider.
pub fn is_model_supported(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    get_claude_model(bare).is_some()
        || get_openai_model(bare).is_some()
        || get_gemini_model(bare).is_some()
        || get_minimax_model(bare).is_some()
}

/// Check if a model supports image inputs.
///
/// Looks up all three provider registries. Unknown models default to `true`.
pub fn model_supports_images(model_id: &str) -> bool {
    let bare = strip_provider_prefix(model_id);
    if let Some(m) = get_claude_model(bare) {
        return m.supports_images;
    }
    if let Some(m) = get_openai_model(bare) {
        return m.supports_images;
    }
    if let Some(m) = get_gemini_model(bare) {
        return m.supports_images;
    }
    if let Some(m) = get_minimax_model(bare) {
        return m.supports_images;
    }
    true
}

/// Get the context window size (in tokens) for a model.
///
/// Looks up the provider-specific model registry (authoritative source of truth).
/// Unknown models default to 200,000 (Anthropic-equivalent fallback).
pub fn model_context_window(model_id: &str) -> u64 {
    let bare = strip_provider_prefix(model_id);
    if let Some(m) = get_claude_model(bare) {
        return m.context_window;
    }
    if let Some(m) = get_openai_model(bare) {
        return m.context_window;
    }
    if let Some(m) = get_gemini_model(bare) {
        return m.context_window;
    }
    if let Some(m) = get_minimax_model(bare) {
        return m.context_window;
    }
    200_000
}

/// Get all known model IDs across all providers.
pub fn all_model_ids() -> Vec<&'static str> {
    let mut ids = all_claude_model_ids();
    ids.extend(all_openai_model_ids());
    ids.extend(all_gemini_model_ids());
    ids.extend(all_minimax_model_ids());
    ids
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::models::model_ids::*;

    // ── detect_provider_from_model ───────────────────────────────────────

    #[test]
    fn detect_explicit_prefix_anthropic() {
        assert_eq!(
            detect_provider_from_model("anthropic/claude-opus-4-6"),
            Some(Provider::Anthropic)
        );
    }

    #[test]
    fn detect_explicit_prefix_openai() {
        assert_eq!(
            detect_provider_from_model("openai/gpt-5.3-codex"),
            Some(Provider::OpenAi)
        );
        assert_eq!(
            detect_provider_from_model("openai-codex/gpt-5.3-codex"),
            Some(Provider::OpenAi)
        );
    }

    #[test]
    fn detect_explicit_prefix_google() {
        assert_eq!(
            detect_provider_from_model("google/gemini-2.5-flash"),
            Some(Provider::Google)
        );
        assert_eq!(
            detect_provider_from_model("gemini/gemini-2.5-flash"),
            Some(Provider::Google)
        );
    }

    #[test]
    fn detect_explicit_prefix_unknown() {
        assert_eq!(detect_provider_from_model("unknown/some-model"), None);
    }

    #[test]
    fn detect_registry_lookup_anthropic() {
        assert_eq!(
            detect_provider_from_model(CLAUDE_OPUS_4_6),
            Some(Provider::Anthropic)
        );
        assert_eq!(
            detect_provider_from_model(CLAUDE_HAIKU_4_5),
            Some(Provider::Anthropic)
        );
        assert_eq!(
            detect_provider_from_model(CLAUDE_3_HAIKU),
            Some(Provider::Anthropic)
        );
    }

    #[test]
    fn detect_registry_lookup_anthropic_sonnet_46() {
        assert_eq!(
            detect_provider_from_model(CLAUDE_SONNET_4_6),
            Some(Provider::Anthropic)
        );
    }

    #[test]
    fn detect_registry_lookup_openai() {
        assert_eq!(
            detect_provider_from_model(GPT_5_3_CODEX),
            Some(Provider::OpenAi)
        );
    }

    #[test]
    fn detect_registry_lookup_openai_gpt_54() {
        assert_eq!(detect_provider_from_model(GPT_5_4), Some(Provider::OpenAi));
        assert_eq!(
            detect_provider_from_model(GPT_5_4_PRO),
            Some(Provider::OpenAi)
        );
        assert_eq!(
            detect_provider_from_model(GPT_5_4_MINI),
            Some(Provider::OpenAi)
        );
    }

    #[test]
    fn detect_registry_lookup_openai_spark() {
        assert_eq!(
            detect_provider_from_model("gpt-5.3-codex-spark"),
            Some(Provider::OpenAi)
        );
    }

    #[test]
    fn detect_registry_lookup_google() {
        assert_eq!(
            detect_provider_from_model(GEMINI_2_5_FLASH),
            Some(Provider::Google)
        );
        assert_eq!(
            detect_provider_from_model(GEMINI_3_PRO_PREVIEW),
            Some(Provider::Google)
        );
    }

    #[test]
    fn detect_family_prefix_claude() {
        assert_eq!(detect_provider_from_model("claude-some-future-model"), None);
    }

    #[test]
    fn detect_family_prefix_gpt() {
        assert_eq!(detect_provider_from_model("gpt-6-turbo"), None);
    }

    #[test]
    fn detect_family_prefix_gemini() {
        assert_eq!(detect_provider_from_model("gemini-4-ultra"), None);
    }

    #[test]
    fn detect_unknown_returns_none() {
        assert_eq!(detect_provider_from_model("some-random-model"), None);
    }

    #[test]
    fn detect_prefixed_unknown_model_returns_none() {
        assert_eq!(detect_provider_from_model("openai/not-a-real-model"), None);
        assert_eq!(
            detect_provider_from_model("anthropic/not-a-real-model"),
            None
        );
        assert_eq!(detect_provider_from_model("google/not-a-real-model"), None);
    }

    // ── strip_provider_prefix ────────────────────────────────────────────

    #[test]
    fn strip_prefix_with_prefix() {
        assert_eq!(
            strip_provider_prefix("openai/gpt-5.3-codex"),
            "gpt-5.3-codex"
        );
    }

    #[test]
    fn strip_prefix_without_prefix() {
        assert_eq!(strip_provider_prefix("claude-opus-4-6"), "claude-opus-4-6");
    }

    // ── is_model_supported ───────────────────────────────────────────────

    #[test]
    fn supported_model() {
        assert!(is_model_supported(CLAUDE_OPUS_4_6));
        assert!(is_model_supported(GPT_5_3_CODEX));
        assert!(is_model_supported(GEMINI_2_5_FLASH));
    }

    #[test]
    fn supported_model_sonnet_46() {
        assert!(is_model_supported("claude-sonnet-4-6"));
    }

    #[test]
    fn supported_model_spark() {
        assert!(is_model_supported("gpt-5.3-codex-spark"));
    }

    #[test]
    fn supported_model_with_prefix() {
        assert!(is_model_supported("anthropic/claude-opus-4-6"));
    }

    #[test]
    fn unsupported_model() {
        assert!(!is_model_supported("totally-unknown-model"));
    }

    // ── model_supports_images ─────────────────────────────────────────────

    #[test]
    fn known_model_supports_images() {
        assert!(model_supports_images(CLAUDE_OPUS_4_6));
        assert!(model_supports_images(GPT_5_3_CODEX));
        assert!(model_supports_images(GEMINI_2_5_FLASH));
    }

    #[test]
    fn spark_does_not_support_images() {
        assert!(!model_supports_images("gpt-5.3-codex-spark"));
    }

    #[test]
    fn unknown_model_defaults_to_supports_images() {
        assert!(model_supports_images("unknown-model"));
    }

    #[test]
    fn prefixed_model_supports_images() {
        assert!(model_supports_images("anthropic/claude-opus-4-6"));
    }

    // ── all_model_ids ────────────────────────────────────────────────────

    // ── MiniMax detection ─────────────────────────────────────────────────

    #[test]
    fn detect_registry_lookup_minimax() {
        assert_eq!(
            detect_provider_from_model(MINIMAX_M2_5),
            Some(Provider::MiniMax)
        );
    }

    #[test]
    fn detect_registry_lookup_minimax_m2() {
        assert_eq!(
            detect_provider_from_model(MINIMAX_M2),
            Some(Provider::MiniMax)
        );
    }

    #[test]
    fn detect_explicit_prefix_minimax() {
        assert_eq!(
            detect_provider_from_model("minimax/MiniMax-M2.5"),
            Some(Provider::MiniMax)
        );
    }

    #[test]
    fn supported_model_minimax() {
        assert!(is_model_supported("MiniMax-M2.5"));
    }

    #[test]
    fn supported_model_minimax_with_prefix() {
        assert!(is_model_supported("minimax/MiniMax-M2.5"));
    }

    #[test]
    fn minimax_no_image_support() {
        assert!(!model_supports_images("MiniMax-M2.5"));
    }

    // ── model_context_window ─────────────────────────────────────────────

    #[test]
    fn context_window_anthropic() {
        assert_eq!(model_context_window(CLAUDE_OPUS_4_6), 1_000_000);
    }

    #[test]
    fn context_window_openai() {
        assert_eq!(model_context_window(GPT_5_3_CODEX), 400_000);
    }

    #[test]
    fn context_window_gpt_54() {
        assert_eq!(model_context_window(GPT_5_4), 272_000);
    }

    #[test]
    fn context_window_gpt_54_pro() {
        assert_eq!(model_context_window(GPT_5_4_PRO), 272_000);
    }

    #[test]
    fn context_window_gpt_54_mini() {
        assert_eq!(model_context_window(GPT_5_4_MINI), 400_000);
    }

    #[test]
    fn gpt_54_mini_supports_images() {
        assert!(model_supports_images(GPT_5_4_MINI));
    }

    #[test]
    fn context_window_google() {
        assert_eq!(model_context_window(GEMINI_2_5_FLASH), 1_048_576);
    }

    #[test]
    fn context_window_minimax() {
        assert_eq!(model_context_window(MINIMAX_M2_5), 204_800);
    }

    #[test]
    fn context_window_prefixed_model() {
        assert_eq!(model_context_window("openai/gpt-5.4"), 272_000);
    }

    #[test]
    fn context_window_unknown_defaults_200k() {
        assert_eq!(model_context_window("unknown-model"), 200_000);
    }

    // ── all_model_ids ────────────────────────────────────────────────────

    #[test]
    fn all_model_ids_includes_all() {
        let ids = all_model_ids();
        assert!(ids.contains(&CLAUDE_OPUS_4_6));
        assert!(ids.contains(&GPT_5_3_CODEX));
        assert!(ids.contains(&GEMINI_2_5_FLASH));
        assert!(ids.contains(&MINIMAX_M2_5));
        // Total = 10 Anthropic + 8 OpenAI + 7 Google + 5 MiniMax = 30
        assert_eq!(ids.len(), 30);
    }
}
