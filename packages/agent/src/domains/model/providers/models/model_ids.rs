//! # Model ID Constants
//!
//! Centralized string constants for all supported model IDs across all providers.
//! Using constants prevents typos and enables compile-time verification.
//!
//! **Note**: Model ID *arrays* are no longer defined here. The provider registries
//! (e.g., `OPENAI_MODELS` in `openai/types.rs`) are the single source of truth.
//! Use `all_openai_model_ids()`, `all_claude_model_ids()`, etc. for runtime lookups.

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic / Claude
// ─────────────────────────────────────────────────────────────────────────────

/// Claude Opus 4.7 — released 2026-04-16, most capable Claude model.
pub const CLAUDE_OPUS_4_7: &str = "claude-opus-4-7";

/// Claude Opus 4.6.
pub const CLAUDE_OPUS_4_6: &str = "claude-opus-4-6";

/// Claude Opus 4.5 (November 2025).
pub const CLAUDE_OPUS_4_5: &str = "claude-opus-4-5-20251101";

/// Claude Sonnet 4.6.
pub const CLAUDE_SONNET_4_6: &str = "claude-sonnet-4-6";

/// Claude Sonnet 4.5.
pub const CLAUDE_SONNET_4_5: &str = "claude-sonnet-4-5-20250929";

/// Claude Haiku 4.5.
pub const CLAUDE_HAIKU_4_5: &str = "claude-haiku-4-5-20251001";

/// Claude Opus 4.1.
pub const CLAUDE_OPUS_4_1: &str = "claude-opus-4-1-20250805";

/// Claude Opus 4.
pub const CLAUDE_OPUS_4: &str = "claude-opus-4-20250514";

/// Claude Sonnet 4.
pub const CLAUDE_SONNET_4: &str = "claude-sonnet-4-20250514";

/// Claude 3.7 Sonnet.
pub const CLAUDE_3_7_SONNET: &str = "claude-3-7-sonnet-20250219";

/// Claude 3 Haiku (retired generation).
pub const CLAUDE_3_HAIKU: &str = "claude-3-haiku-20240307";

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI / GPT
// ─────────────────────────────────────────────────────────────────────────────

/// GPT 5.5 — current `OpenAI` flagship.
pub const GPT_5_5: &str = "gpt-5.5";

/// GPT 5.5 dated snapshot.
pub const GPT_5_5_2026_04_23: &str = "gpt-5.5-2026-04-23";

/// GPT 5.4 — previous `OpenAI` flagship.
pub const GPT_5_4: &str = "gpt-5.4";

/// GPT 5.4 Pro — highest capability tier on the Platform API.
pub const GPT_5_4_PRO: &str = "gpt-5.4-pro";

/// GPT 5.4 Mini — smaller, faster variant of GPT-5.4 for high-volume agentic workloads.
pub const GPT_5_4_MINI: &str = "gpt-5.4-mini";

/// GPT 5.4 Nano — smallest GPT-5.4 variant on the Platform API.
pub const GPT_5_4_NANO: &str = "gpt-5.4-nano";

/// GPT 5.5 Pro — non-streaming Platform model, hidden from the picker.
pub const GPT_5_5_PRO: &str = "gpt-5.5-pro";

/// GPT 5.2 Pro — higher-compute GPT-5.2 variant on the Platform API.
pub const GPT_5_2_PRO: &str = "gpt-5.2-pro";

/// GPT 5.3 Codex — `OpenAI` flagship.
pub const GPT_5_3_CODEX: &str = "gpt-5.3-codex";

/// GPT 5.3 Codex Spark — fast distilled model (research preview).
pub const GPT_5_3_CODEX_SPARK: &str = "gpt-5.3-codex-spark";

/// GPT 5.2 — current canonical ID for GPT-5.2.
pub const GPT_5_2: &str = "gpt-5.2";

/// GPT 5.1 — previous GPT-5 model on the Platform API.
pub const GPT_5_1: &str = "gpt-5.1";

/// GPT 5 — previous GPT-5 model on the Platform API.
pub const GPT_5: &str = "gpt-5";

/// GPT 5 Mini.
pub const GPT_5_MINI: &str = "gpt-5-mini";

/// GPT 5 Nano.
pub const GPT_5_NANO: &str = "gpt-5-nano";

/// GPT 5 Pro.
pub const GPT_5_PRO: &str = "gpt-5-pro";

/// GPT 5 Codex.
pub const GPT_5_CODEX: &str = "gpt-5-codex";

/// GPT 5.2 Codex — retired provider alias for GPT-5.2.
pub const GPT_5_2_CODEX: &str = "gpt-5.2-codex";

/// GPT 5.1 Codex.
pub const GPT_5_1_CODEX: &str = "gpt-5.1-codex";

/// GPT 5.1 Codex Max.
pub const GPT_5_1_CODEX_MAX: &str = "gpt-5.1-codex-max";

/// GPT 5.1 Codex Mini.
pub const GPT_5_1_CODEX_MINI: &str = "gpt-5.1-codex-mini";

/// Codex Mini Latest.
pub const CODEX_MINI_LATEST: &str = "codex-mini-latest";

/// GPT 5.3 Chat Latest.
pub const GPT_5_3_CHAT_LATEST: &str = "gpt-5.3-chat-latest";

/// GPT 5.2 Chat Latest.
pub const GPT_5_2_CHAT_LATEST: &str = "gpt-5.2-chat-latest";

/// GPT 5.1 Chat Latest.
pub const GPT_5_1_CHAT_LATEST: &str = "gpt-5.1-chat-latest";

/// GPT 5 Chat Latest.
pub const GPT_5_CHAT_LATEST: &str = "gpt-5-chat-latest";

/// o3 reasoning model.
pub const O3: &str = "o3";

/// o3 Pro — non-streaming Platform model, hidden from the picker.
pub const O3_PRO: &str = "o3-pro";

/// o4 Mini reasoning model.
pub const O4_MINI: &str = "o4-mini";

/// o3 Mini reasoning model.
pub const O3_MINI: &str = "o3-mini";

/// o1 reasoning model.
pub const O1: &str = "o1";

/// o1 Mini reasoning model.
pub const O1_MINI: &str = "o1-mini";

/// o1 Preview reasoning model.
pub const O1_PREVIEW: &str = "o1-preview";

/// o1 Pro — non-streaming Platform model, hidden from the picker.
pub const O1_PRO: &str = "o1-pro";

/// GPT 4.1.
pub const GPT_4_1: &str = "gpt-4.1";

/// GPT 4.1 Mini.
pub const GPT_4_1_MINI: &str = "gpt-4.1-mini";

/// GPT 4.1 Nano.
pub const GPT_4_1_NANO: &str = "gpt-4.1-nano";

/// GPT 4o.
pub const GPT_4O: &str = "gpt-4o";

/// GPT 4o Mini.
pub const GPT_4O_MINI: &str = "gpt-4o-mini";

/// GPT 4.5 Preview.
pub const GPT_4_5_PREVIEW: &str = "gpt-4.5-preview";

/// GPT 4 Turbo.
pub const GPT_4_TURBO: &str = "gpt-4-turbo";

/// GPT 4 Turbo Preview — non-streaming Platform model, hidden from the picker.
pub const GPT_4_TURBO_PREVIEW: &str = "gpt-4-turbo-preview";

/// GPT 4.
pub const GPT_4: &str = "gpt-4";

/// GPT 3.5 Turbo — non-streaming Platform model, hidden from the picker.
pub const GPT_3_5_TURBO: &str = "gpt-3.5-turbo";

/// ChatGPT 4o Latest.
pub const CHATGPT_4O_LATEST: &str = "chatgpt-4o-latest";

/// GPT-OSS 120B.
pub const GPT_OSS_120B: &str = "gpt-oss-120b";

/// GPT-OSS 20B.
pub const GPT_OSS_20B: &str = "gpt-oss-20b";

// ─────────────────────────────────────────────────────────────────────────────
// Google / Gemini
// ─────────────────────────────────────────────────────────────────────────────

/// Gemini 3.1 Pro (preview) — latest Gemini.
pub const GEMINI_3_1_PRO_PREVIEW: &str = "gemini-3.1-pro-preview";

/// Gemini 3 Pro (preview) — retired 2026-03-09.
pub const GEMINI_3_PRO_PREVIEW: &str = "gemini-3-pro-preview";

/// Gemini 3 Flash (preview).
pub const GEMINI_3_FLASH_PREVIEW: &str = "gemini-3-flash-preview";

/// Gemini 2.5 Pro.
pub const GEMINI_2_5_PRO: &str = "gemini-2.5-pro";

/// Gemini 2.5 Flash.
pub const GEMINI_2_5_FLASH: &str = "gemini-2.5-flash";

/// Gemini 3.1 Flash Lite (preview) — cost-optimized for high-volume agentic tasks.
pub const GEMINI_3_1_FLASH_LITE_PREVIEW: &str = "gemini-3.1-flash-lite-preview";

/// Gemini 2.5 Flash Lite.
pub const GEMINI_2_5_FLASH_LITE: &str = "gemini-2.5-flash-lite";

// ─────────────────────────────────────────────────────────────────────────────
// MiniMax
// ─────────────────────────────────────────────────────────────────────────────

/// `MiniMax` M2.7 — latest `MiniMax` model.
pub const MINIMAX_M2_7: &str = "MiniMax-M2.7";

/// `MiniMax` M2.7 Highspeed.
pub const MINIMAX_M2_7_HIGHSPEED: &str = "MiniMax-M2.7-highspeed";

/// `MiniMax` M2.5.
pub const MINIMAX_M2_5: &str = "MiniMax-M2.5";

/// `MiniMax` M2.5 Highspeed.
pub const MINIMAX_M2_5_HIGHSPEED: &str = "MiniMax-M2.5-highspeed";

/// `MiniMax` M2.1.
pub const MINIMAX_M2_1: &str = "MiniMax-M2.1";

/// `MiniMax` M2.1 Highspeed.
pub const MINIMAX_M2_1_HIGHSPEED: &str = "MiniMax-M2.1-highspeed";

/// `MiniMax` M2.
pub const MINIMAX_M2: &str = "MiniMax-M2";

/// Default `MiniMax` model.
pub const DEFAULT_MINIMAX_MODEL: &str = MINIMAX_M2_7;

// ─────────────────────────────────────────────────────────────────────────────
// Kimi (Moonshot AI)
// ─────────────────────────────────────────────────────────────────────────────

/// Kimi K2.5 — flagship model with vision and thinking.
pub const KIMI_K2_5: &str = "kimi-k2.5";

/// Kimi K2 0905 Preview.
pub const KIMI_K2_0905_PREVIEW: &str = "kimi-k2-0905-preview";

/// Kimi K2 0711 Preview.
pub const KIMI_K2_0711_PREVIEW: &str = "kimi-k2-0711-preview";

/// Kimi K2 Turbo Preview — high-speed variant.
pub const KIMI_K2_TURBO_PREVIEW: &str = "kimi-k2-turbo-preview";

/// Kimi K2 Thinking — dedicated thinking model.
pub const KIMI_K2_THINKING: &str = "kimi-k2-thinking";

/// Kimi K2 Thinking Turbo — high-speed thinking model.
pub const KIMI_K2_THINKING_TURBO: &str = "kimi-k2-thinking-turbo";

/// Moonshot V1 8K (retired generation).
pub const MOONSHOT_V1_8K: &str = "moonshot-v1-8k";

/// Moonshot V1 32K (retired generation).
pub const MOONSHOT_V1_32K: &str = "moonshot-v1-32k";

/// Moonshot V1 128K (retired generation).
pub const MOONSHOT_V1_128K: &str = "moonshot-v1-128k";

/// Default Kimi model.
pub const DEFAULT_KIMI_MODEL: &str = KIMI_K2_5;

// ─────────────────────────────────────────────────────────────────────────────
// Ollama (local models)
// ─────────────────────────────────────────────────────────────────────────────

/// Gemma 4 E4B — 4.5B effective dense model (edge/validation).
pub const GEMMA4_E4B: &str = "gemma4:e4b";

/// Gemma 4 26B MoE — 26B total, 3.8B active per token.
pub const GEMMA4_26B: &str = "gemma4:26b";

/// Default Ollama model.
pub const DEFAULT_OLLAMA_MODEL: &str = GEMMA4_E4B;

// ─────────────────────────────────────────────────────────────────────────────
// Role-Based Aliases
// ─────────────────────────────────────────────────────────────────────────────

/// Default model for subagent tasks (fast, cheap).
pub const SUBAGENT_MODEL: &str = CLAUDE_HAIKU_4_5;

/// Default API model (most capable).
pub const DEFAULT_API_MODEL: &str = CLAUDE_OPUS_4_6;

/// Default server model (balanced).
pub const DEFAULT_SERVER_MODEL: &str = CLAUDE_SONNET_4;

/// Default Google model.
pub const DEFAULT_GOOGLE_MODEL: &str = GEMINI_2_5_FLASH;

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::model::providers::anthropic::types::all_claude_model_ids;
    use crate::domains::model::providers::google::types::all_gemini_model_ids;
    use crate::domains::model::providers::kimi::types::all_kimi_model_ids;
    use crate::domains::model::providers::minimax::types::all_minimax_model_ids;
    use crate::domains::model::providers::ollama::types::all_ollama_model_ids;
    use crate::domains::model::providers::openai::types::all_openai_model_ids;

    #[test]
    fn anthropic_ids_not_empty() {
        let ids = all_claude_model_ids();
        assert!(!ids.is_empty());
        assert!(ids.contains(&CLAUDE_OPUS_4_6));
        assert!(ids.contains(&CLAUDE_SONNET_4_6));
        assert!(ids.contains(&CLAUDE_HAIKU_4_5));
    }

    #[test]
    fn openai_ids_not_empty() {
        let ids = all_openai_model_ids();
        assert!(!ids.is_empty());
        assert!(ids.contains(&GPT_5_3_CODEX));
    }

    #[test]
    fn openai_ids_contains_gpt_54() {
        let ids = all_openai_model_ids();
        assert!(ids.contains(&GPT_5_4));
        assert!(ids.contains(&GPT_5_4_PRO));
        assert!(ids.contains(&GPT_5_4_MINI));
    }

    #[test]
    fn openai_ids_contains_spark() {
        let ids = all_openai_model_ids();
        assert!(ids.contains(&GPT_5_3_CODEX_SPARK));
    }

    #[test]
    fn google_ids_not_empty() {
        let ids = all_gemini_model_ids();
        assert!(!ids.is_empty());
        assert!(ids.contains(&GEMINI_2_5_FLASH));
    }

    #[test]
    fn role_aliases_point_to_valid_models() {
        let anthropic = all_claude_model_ids();
        let google = all_gemini_model_ids();
        assert!(anthropic.contains(&SUBAGENT_MODEL));
        assert!(anthropic.contains(&DEFAULT_API_MODEL));
        assert!(anthropic.contains(&DEFAULT_SERVER_MODEL));
        assert!(google.contains(&DEFAULT_GOOGLE_MODEL));
    }

    #[test]
    fn minimax_ids_not_empty() {
        let ids = all_minimax_model_ids();
        assert!(!ids.is_empty());
        assert!(ids.contains(&MINIMAX_M2_7));
        assert!(ids.contains(&MINIMAX_M2_5));
    }

    #[test]
    fn minimax_id_format() {
        for id in all_minimax_model_ids() {
            assert!(
                id.starts_with("MiniMax-"),
                "MiniMax model ID should start with 'MiniMax-': {id}"
            );
        }
    }

    #[test]
    fn kimi_ids_not_empty() {
        let ids = all_kimi_model_ids();
        assert_eq!(ids.len(), 9);
        assert!(ids.contains(&KIMI_K2_5));
        assert!(ids.contains(&KIMI_K2_THINKING));
        assert!(ids.contains(&MOONSHOT_V1_128K));
    }

    #[test]
    fn kimi_id_format() {
        for id in all_kimi_model_ids() {
            assert!(
                id.starts_with("kimi-") || id.starts_with("moonshot-"),
                "Kimi model ID should start with 'kimi-' or 'moonshot-': {id}"
            );
        }
    }

    #[test]
    fn no_duplicate_ids() {
        let mut all: Vec<&str> = Vec::new();
        all.extend(all_claude_model_ids());
        all.extend(all_openai_model_ids());
        all.extend(all_gemini_model_ids());
        all.extend(all_minimax_model_ids());
        all.extend(all_kimi_model_ids());
        all.extend(all_ollama_model_ids());

        let unique: std::collections::HashSet<&&str> = all.iter().collect();
        assert_eq!(all.len(), unique.len(), "duplicate model IDs found");
    }

    #[test]
    fn claude_id_format() {
        for id in all_claude_model_ids() {
            assert!(
                id.starts_with("claude-"),
                "Anthropic model ID should start with 'claude-': {id}"
            );
        }
    }

    #[test]
    fn openai_id_format() {
        for id in all_openai_model_ids() {
            assert!(
                id.starts_with("gpt-")
                    || id.starts_with("o")
                    || id.starts_with("codex-")
                    || id.starts_with("chatgpt-"),
                "OpenAI model ID should use a known OpenAI family prefix: {id}"
            );
        }
    }

    #[test]
    fn ollama_ids_not_empty() {
        let ids = all_ollama_model_ids();
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&GEMMA4_E4B));
        assert!(ids.contains(&GEMMA4_26B));
    }

    #[test]
    fn ollama_id_format() {
        for id in all_ollama_model_ids() {
            assert!(
                id.starts_with("gemma4:"),
                "Ollama model ID should start with 'gemma4:': {id}"
            );
        }
    }

    #[test]
    fn google_id_format() {
        for id in all_gemini_model_ids() {
            assert!(
                id.starts_with("gemini-"),
                "Google model ID should start with 'gemini-': {id}"
            );
        }
    }
}
