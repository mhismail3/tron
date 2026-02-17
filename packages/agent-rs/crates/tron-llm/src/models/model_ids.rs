//! # Model ID Constants
//!
//! Centralized string constants for all supported model IDs across all providers.
//! Using constants prevents typos and enables compile-time verification.

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic / Claude
// ─────────────────────────────────────────────────────────────────────────────

/// Claude Opus 4.6 — latest and most capable.
pub const CLAUDE_OPUS_4_6: &str = "claude-opus-4-6";

/// Claude Opus 4.5 (November 2025).
pub const CLAUDE_OPUS_4_5: &str = "claude-opus-4-5-20251101";

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

/// Claude 3 Haiku (legacy).
pub const CLAUDE_3_HAIKU: &str = "claude-3-haiku-20240307";

// ─────────────────────────────────────────────────────────────────────────────
// OpenAI / GPT (Codex)
// ─────────────────────────────────────────────────────────────────────────────

/// GPT 5.3 Codex — latest `OpenAI` flagship.
pub const GPT_5_3_CODEX: &str = "gpt-5.3-codex";

/// GPT 5.3 Codex Spark — fast distilled model (research preview).
pub const GPT_5_3_CODEX_SPARK: &str = "gpt-5.3-codex-spark";

/// GPT 5.2 Codex.
pub const GPT_5_2_CODEX: &str = "gpt-5.2-codex";

/// GPT 5.1 Codex Max.
pub const GPT_5_1_CODEX_MAX: &str = "gpt-5.1-codex-max";

/// GPT 5.1 Codex Mini.
pub const GPT_5_1_CODEX_MINI: &str = "gpt-5.1-codex-mini";

// ─────────────────────────────────────────────────────────────────────────────
// Google / Gemini
// ─────────────────────────────────────────────────────────────────────────────

/// Gemini 3 Pro (preview).
pub const GEMINI_3_PRO_PREVIEW: &str = "gemini-3-pro-preview";

/// Gemini 3 Flash (preview).
pub const GEMINI_3_FLASH_PREVIEW: &str = "gemini-3-flash-preview";

/// Gemini 2.5 Pro.
pub const GEMINI_2_5_PRO: &str = "gemini-2.5-pro";

/// Gemini 2.5 Flash.
pub const GEMINI_2_5_FLASH: &str = "gemini-2.5-flash";

/// Gemini 2.5 Flash Lite.
pub const GEMINI_2_5_FLASH_LITE: &str = "gemini-2.5-flash-lite";

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

/// All Anthropic model IDs.
pub const ALL_ANTHROPIC_MODEL_IDS: &[&str] = &[
    CLAUDE_OPUS_4_6,
    CLAUDE_OPUS_4_5,
    CLAUDE_SONNET_4_5,
    CLAUDE_HAIKU_4_5,
    CLAUDE_OPUS_4_1,
    CLAUDE_OPUS_4,
    CLAUDE_SONNET_4,
    CLAUDE_3_7_SONNET,
    CLAUDE_3_HAIKU,
];

/// All `OpenAI` model IDs.
pub const ALL_OPENAI_MODEL_IDS: &[&str] = &[
    GPT_5_3_CODEX,
    GPT_5_3_CODEX_SPARK,
    GPT_5_2_CODEX,
    GPT_5_1_CODEX_MAX,
    GPT_5_1_CODEX_MINI,
];

/// All Google model IDs.
pub const ALL_GOOGLE_MODEL_IDS: &[&str] = &[
    GEMINI_3_PRO_PREVIEW,
    GEMINI_3_FLASH_PREVIEW,
    GEMINI_2_5_PRO,
    GEMINI_2_5_FLASH,
    GEMINI_2_5_FLASH_LITE,
];

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_ids_not_empty() {
        assert!(!ALL_ANTHROPIC_MODEL_IDS.is_empty());
        assert!(ALL_ANTHROPIC_MODEL_IDS.contains(&CLAUDE_OPUS_4_6));
        assert!(ALL_ANTHROPIC_MODEL_IDS.contains(&CLAUDE_HAIKU_4_5));
    }

    #[test]
    fn openai_ids_not_empty() {
        assert!(!ALL_OPENAI_MODEL_IDS.is_empty());
        assert!(ALL_OPENAI_MODEL_IDS.contains(&GPT_5_3_CODEX));
    }

    #[test]
    fn openai_ids_contains_spark() {
        assert!(ALL_OPENAI_MODEL_IDS.contains(&GPT_5_3_CODEX_SPARK));
    }

    #[test]
    fn google_ids_not_empty() {
        assert!(!ALL_GOOGLE_MODEL_IDS.is_empty());
        assert!(ALL_GOOGLE_MODEL_IDS.contains(&GEMINI_2_5_FLASH));
    }

    #[test]
    fn role_aliases_point_to_valid_models() {
        assert!(ALL_ANTHROPIC_MODEL_IDS.contains(&SUBAGENT_MODEL));
        assert!(ALL_ANTHROPIC_MODEL_IDS.contains(&DEFAULT_API_MODEL));
        assert!(ALL_ANTHROPIC_MODEL_IDS.contains(&DEFAULT_SERVER_MODEL));
        assert!(ALL_GOOGLE_MODEL_IDS.contains(&DEFAULT_GOOGLE_MODEL));
    }

    #[test]
    fn no_duplicate_ids() {
        let mut all: Vec<&str> = Vec::new();
        all.extend_from_slice(ALL_ANTHROPIC_MODEL_IDS);
        all.extend_from_slice(ALL_OPENAI_MODEL_IDS);
        all.extend_from_slice(ALL_GOOGLE_MODEL_IDS);

        let unique: std::collections::HashSet<&&str> = all.iter().collect();
        assert_eq!(all.len(), unique.len(), "duplicate model IDs found");
    }

    #[test]
    fn claude_id_format() {
        for id in ALL_ANTHROPIC_MODEL_IDS {
            assert!(
                id.starts_with("claude-"),
                "Anthropic model ID should start with 'claude-': {id}"
            );
        }
    }

    #[test]
    fn openai_id_format() {
        for id in ALL_OPENAI_MODEL_IDS {
            assert!(
                id.starts_with("gpt-"),
                "OpenAI model ID should start with 'gpt-': {id}"
            );
        }
    }

    #[test]
    fn google_id_format() {
        for id in ALL_GOOGLE_MODEL_IDS {
            assert!(
                id.starts_with("gemini-"),
                "Google model ID should start with 'gemini-': {id}"
            );
        }
    }
}
