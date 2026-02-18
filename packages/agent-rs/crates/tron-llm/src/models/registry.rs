//! # Model Registry
//!
//! Unified model registry for provider detection, model lookup, and capability queries.
//! Each provider maintains its own detailed model registry (pricing, capabilities, etc.)
//! in its respective crate. This module provides cross-provider utilities.

use super::model_ids::{ALL_ANTHROPIC_MODEL_IDS, ALL_GOOGLE_MODEL_IDS, ALL_OPENAI_MODEL_IDS};
use super::types::ProviderType;

/// Detect which provider serves a given model ID.
///
/// Resolution order:
/// 1. Explicit prefix (e.g., `"openai/gpt-5"` → `OpenAi`)
/// 2. Registry lookup (exact match against known model IDs)
///
/// Unknown model IDs always return `None` (strict fail-fast behavior).
pub fn detect_provider_from_model(model_id: &str, strict: bool) -> Option<ProviderType> {
    // Keep the parameter for API stability while enforcing strict behavior.
    let _ = strict;

    // 1. Explicit prefix: "provider/model". Prefix is accepted only when the
    // bare model exists in that provider's registry.
    if let Some((prefix, bare_model)) = model_id.split_once('/') {
        return match prefix {
            "anthropic" if ALL_ANTHROPIC_MODEL_IDS.contains(&bare_model) => {
                Some(ProviderType::Anthropic)
            }
            "openai" | "openai-codex" if ALL_OPENAI_MODEL_IDS.contains(&bare_model) => {
                Some(ProviderType::OpenAi)
            }
            "google" | "gemini" if ALL_GOOGLE_MODEL_IDS.contains(&bare_model) => {
                Some(ProviderType::Google)
            }
            _ => None,
        };
    }

    // 2. Registry lookup (exact match)
    if ALL_ANTHROPIC_MODEL_IDS.contains(&model_id) {
        return Some(ProviderType::Anthropic);
    }
    if ALL_OPENAI_MODEL_IDS.contains(&model_id) {
        return Some(ProviderType::OpenAi);
    }
    if ALL_GOOGLE_MODEL_IDS.contains(&model_id) {
        return Some(ProviderType::Google);
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
    ALL_ANTHROPIC_MODEL_IDS.contains(&bare)
        || ALL_OPENAI_MODEL_IDS.contains(&bare)
        || ALL_GOOGLE_MODEL_IDS.contains(&bare)
}

/// Get all known model IDs across all providers.
pub fn all_model_ids() -> Vec<&'static str> {
    let mut ids = Vec::with_capacity(
        ALL_ANTHROPIC_MODEL_IDS.len() + ALL_OPENAI_MODEL_IDS.len() + ALL_GOOGLE_MODEL_IDS.len(),
    );
    ids.extend_from_slice(ALL_ANTHROPIC_MODEL_IDS);
    ids.extend_from_slice(ALL_OPENAI_MODEL_IDS);
    ids.extend_from_slice(ALL_GOOGLE_MODEL_IDS);
    ids
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::model_ids::*;

    // ── detect_provider_from_model ───────────────────────────────────────

    #[test]
    fn detect_explicit_prefix_anthropic() {
        assert_eq!(
            detect_provider_from_model("anthropic/claude-opus-4-6", false),
            Some(ProviderType::Anthropic)
        );
    }

    #[test]
    fn detect_explicit_prefix_openai() {
        assert_eq!(
            detect_provider_from_model("openai/gpt-5.3-codex", false),
            Some(ProviderType::OpenAi)
        );
        assert_eq!(
            detect_provider_from_model("openai-codex/gpt-5.3-codex", false),
            Some(ProviderType::OpenAi)
        );
    }

    #[test]
    fn detect_explicit_prefix_google() {
        assert_eq!(
            detect_provider_from_model("google/gemini-2.5-flash", false),
            Some(ProviderType::Google)
        );
        assert_eq!(
            detect_provider_from_model("gemini/gemini-2.5-flash", false),
            Some(ProviderType::Google)
        );
    }

    #[test]
    fn detect_explicit_prefix_unknown() {
        assert_eq!(
            detect_provider_from_model("unknown/some-model", false),
            None
        );
    }

    #[test]
    fn detect_registry_lookup_anthropic() {
        assert_eq!(
            detect_provider_from_model(CLAUDE_OPUS_4_6, false),
            Some(ProviderType::Anthropic)
        );
        assert_eq!(
            detect_provider_from_model(CLAUDE_HAIKU_4_5, false),
            Some(ProviderType::Anthropic)
        );
        assert_eq!(
            detect_provider_from_model(CLAUDE_3_HAIKU, false),
            Some(ProviderType::Anthropic)
        );
    }

    #[test]
    fn detect_registry_lookup_anthropic_sonnet_46() {
        assert_eq!(
            detect_provider_from_model(CLAUDE_SONNET_4_6, false),
            Some(ProviderType::Anthropic)
        );
    }

    #[test]
    fn detect_registry_lookup_openai() {
        assert_eq!(
            detect_provider_from_model(GPT_5_3_CODEX, false),
            Some(ProviderType::OpenAi)
        );
    }

    #[test]
    fn detect_registry_lookup_openai_spark() {
        assert_eq!(
            detect_provider_from_model("gpt-5.3-codex-spark", false),
            Some(ProviderType::OpenAi)
        );
    }

    #[test]
    fn detect_registry_lookup_google() {
        assert_eq!(
            detect_provider_from_model(GEMINI_2_5_FLASH, false),
            Some(ProviderType::Google)
        );
        assert_eq!(
            detect_provider_from_model(GEMINI_3_PRO_PREVIEW, false),
            Some(ProviderType::Google)
        );
    }

    #[test]
    fn detect_family_prefix_claude() {
        assert_eq!(
            detect_provider_from_model("claude-some-future-model", false),
            None
        );
    }

    #[test]
    fn detect_family_prefix_gpt() {
        assert_eq!(detect_provider_from_model("gpt-6-turbo", false), None);
    }

    #[test]
    fn detect_family_prefix_gemini() {
        assert_eq!(detect_provider_from_model("gemini-4-ultra", false), None);
    }

    #[test]
    fn detect_unknown_returns_none() {
        assert_eq!(detect_provider_from_model("some-random-model", false), None);
    }

    #[test]
    fn detect_unknown_strict_returns_none() {
        assert_eq!(detect_provider_from_model("some-random-model", true), None);
    }

    #[test]
    fn detect_prefixed_unknown_model_returns_none() {
        assert_eq!(
            detect_provider_from_model("openai/not-a-real-model", false),
            None
        );
        assert_eq!(
            detect_provider_from_model("anthropic/not-a-real-model", false),
            None
        );
        assert_eq!(
            detect_provider_from_model("google/not-a-real-model", false),
            None
        );
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

    // ── all_model_ids ────────────────────────────────────────────────────

    #[test]
    fn all_model_ids_includes_all() {
        let ids = all_model_ids();
        assert!(ids.contains(&CLAUDE_OPUS_4_6));
        assert!(ids.contains(&GPT_5_3_CODEX));
        assert!(ids.contains(&GEMINI_2_5_FLASH));
        assert_eq!(
            ids.len(),
            ALL_ANTHROPIC_MODEL_IDS.len() + ALL_OPENAI_MODEL_IDS.len() + ALL_GOOGLE_MODEL_IDS.len()
        );
    }
}
