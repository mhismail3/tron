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
use crate::llm::kimi::types::{all_kimi_model_ids, get_kimi_model};
use crate::llm::minimax::types::{all_minimax_model_ids, get_minimax_model};
use crate::llm::ollama::types::{all_ollama_model_ids, get_ollama_model};
use crate::llm::openai::types::{all_openai_model_ids, get_openai_model};
use crate::core::messages::Provider;

/// Detect which provider serves a given model ID.
///
/// Resolution order:
/// 1. Explicit prefix (e.g., `"openai/gpt-5"` → `OpenAi`)
/// 2. Registry lookup (exact match in provider `HashMap` — O(1))
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
            "kimi" | "moonshot" if get_kimi_model(bare_model).is_some() => Some(Provider::Kimi),
            "ollama" if get_ollama_model(bare_model).is_some() => Some(Provider::Ollama),
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
    if get_kimi_model(model_id).is_some() {
        return Some(Provider::Kimi);
    }
    if get_ollama_model(model_id).is_some() {
        return Some(Provider::Ollama);
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
        || get_kimi_model(bare).is_some()
        || get_ollama_model(bare).is_some()
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
    if let Some(m) = get_kimi_model(bare) {
        return m.supports_images;
    }
    if let Some(m) = get_ollama_model(bare) {
        return m.supports_images;
    }
    true
}

/// Level of document support for a model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DocumentSupport {
    /// Full document support (PDF, text, JSON, etc.) — Anthropic.
    Full,
    /// PDF-only support — Google Gemini.
    PdfOnly,
    /// No native document support — content must be extracted as text.
    None,
}

/// Check what level of document support a model has.
///
/// Anthropic models natively handle PDFs and other documents.
/// Gemini models handle PDFs only (other doc types silently dropped).
/// OpenAI, Kimi, and MiniMax have no native document reading.
/// Unknown models default to `None`.
pub fn model_supports_documents(model_id: &str) -> DocumentSupport {
    let bare = strip_provider_prefix(model_id);
    if get_claude_model(bare).is_some() {
        return DocumentSupport::Full;
    }
    if get_gemini_model(bare).is_some() {
        return DocumentSupport::PdfOnly;
    }
    // OpenAI, Kimi, MiniMax, Ollama: no native document support.
    DocumentSupport::None
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
    if let Some(m) = get_kimi_model(bare) {
        return m.context_window;
    }
    if let Some(m) = get_ollama_model(bare) {
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
    ids.extend(all_kimi_model_ids());
    ids.extend(all_ollama_model_ids());
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
    fn detect_registry_lookup_minimax_m2_7() {
        assert_eq!(
            detect_provider_from_model(MINIMAX_M2_7),
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

    // ── Kimi detection ──────────────────────────────────────────────────

    #[test]
    fn detect_registry_lookup_kimi() {
        assert_eq!(
            detect_provider_from_model(KIMI_K2_5),
            Some(Provider::Kimi)
        );
    }

    #[test]
    fn detect_registry_lookup_kimi_thinking() {
        assert_eq!(
            detect_provider_from_model(KIMI_K2_THINKING),
            Some(Provider::Kimi)
        );
    }

    #[test]
    fn detect_registry_lookup_moonshot() {
        assert_eq!(
            detect_provider_from_model(MOONSHOT_V1_128K),
            Some(Provider::Kimi)
        );
    }

    #[test]
    fn detect_explicit_prefix_kimi() {
        assert_eq!(
            detect_provider_from_model("kimi/kimi-k2.5"),
            Some(Provider::Kimi)
        );
    }

    #[test]
    fn supported_model_kimi() {
        assert!(is_model_supported("kimi-k2.5"));
        assert!(is_model_supported("moonshot-v1-8k"));
    }

    #[test]
    fn kimi_image_support() {
        assert!(model_supports_images("kimi-k2.5"));
        assert!(!model_supports_images("kimi-k2-0905-preview"));
        assert!(!model_supports_images("moonshot-v1-8k"));
    }

    #[test]
    fn context_window_kimi() {
        assert_eq!(model_context_window(KIMI_K2_5), 262_144);
        assert_eq!(model_context_window(MOONSHOT_V1_8K), 8_192);
    }

    // ── model_supports_documents ─────────────────────────────────────────

    #[test]
    fn claude_models_full_document_support() {
        assert_eq!(
            model_supports_documents(CLAUDE_OPUS_4_6),
            DocumentSupport::Full
        );
        assert_eq!(
            model_supports_documents(CLAUDE_HAIKU_4_5),
            DocumentSupport::Full
        );
    }

    #[test]
    fn gemini_models_pdf_only() {
        assert_eq!(
            model_supports_documents(GEMINI_2_5_FLASH),
            DocumentSupport::PdfOnly
        );
    }

    #[test]
    fn openai_models_no_document_support() {
        assert_eq!(
            model_supports_documents(GPT_5_3_CODEX),
            DocumentSupport::None
        );
    }

    #[test]
    fn kimi_models_no_document_support() {
        assert_eq!(
            model_supports_documents(KIMI_K2_5),
            DocumentSupport::None
        );
    }

    #[test]
    fn minimax_models_no_document_support() {
        assert_eq!(
            model_supports_documents(MINIMAX_M2_5),
            DocumentSupport::None
        );
    }

    #[test]
    fn unknown_model_documents_defaults_to_none() {
        assert_eq!(
            model_supports_documents("unknown-model"),
            DocumentSupport::None
        );
    }

    // ── Ollama detection ──────────────────────────────────────────────────

    #[test]
    fn detect_registry_lookup_ollama_e4b() {
        assert_eq!(
            detect_provider_from_model(GEMMA4_E4B),
            Some(Provider::Ollama)
        );
    }

    #[test]
    fn detect_registry_lookup_ollama_26b() {
        assert_eq!(
            detect_provider_from_model(GEMMA4_26B),
            Some(Provider::Ollama)
        );
    }

    #[test]
    fn detect_explicit_prefix_ollama() {
        assert_eq!(
            detect_provider_from_model("ollama/gemma4:e4b"),
            Some(Provider::Ollama)
        );
    }

    #[test]
    fn supported_model_ollama() {
        assert!(is_model_supported("gemma4:e4b"));
        assert!(is_model_supported("gemma4:26b"));
    }

    #[test]
    fn ollama_image_support() {
        assert!(model_supports_images("gemma4:e4b"));
        assert!(model_supports_images("gemma4:26b"));
    }

    #[test]
    fn ollama_no_document_support() {
        assert_eq!(
            model_supports_documents("gemma4:e4b"),
            DocumentSupport::None
        );
    }

    #[test]
    fn context_window_ollama() {
        assert_eq!(model_context_window(GEMMA4_E4B), 65_536);
        assert_eq!(model_context_window(GEMMA4_26B), 65_536);
    }

    #[test]
    fn prefixed_model_document_support() {
        assert_eq!(
            model_supports_documents("anthropic/claude-opus-4-6"),
            DocumentSupport::Full
        );
        assert_eq!(
            model_supports_documents("google/gemini-2.5-flash"),
            DocumentSupport::PdfOnly
        );
    }

    // ── all_model_ids ────────────────────────────────────────────────────

    #[test]
    fn all_model_ids_includes_all() {
        let ids = all_model_ids();
        assert!(ids.contains(&CLAUDE_OPUS_4_6));
        assert!(ids.contains(&GPT_5_3_CODEX));
        assert!(ids.contains(&GEMINI_2_5_FLASH));
        assert!(ids.contains(&MINIMAX_M2_7));
        assert!(ids.contains(&MINIMAX_M2_5));
        assert!(ids.contains(&GEMMA4_E4B));
        // Total = 10 Anthropic + 8 OpenAI + 7 Google + 7 MiniMax + 9 Kimi + 2 Ollama = 43
        assert_eq!(ids.len(), 43);
    }
}
