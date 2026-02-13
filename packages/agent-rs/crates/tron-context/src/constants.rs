//! Context subsystem constants.
//!
//! Shared constants for the LLM summarizer, context manager,
//! system prompts, and token estimator.

// =============================================================================
// Token Estimation
// =============================================================================

/// Approximate characters per token (consistent with Anthropic's tokenizer).
pub const CHARS_PER_TOKEN: u32 = 4;

/// Minimum token estimate for any image.
pub const MIN_IMAGE_TOKENS: u32 = 85;

/// Default token estimate for URL-referenced images (~1024x1024).
pub const DEFAULT_URL_IMAGE_TOKENS: u32 = 1500;

// =============================================================================
// Context Manager — tool result budgeting
// =============================================================================

/// Minimum tokens allocated for a tool result, even under heavy context pressure.
pub const TOOL_RESULT_MIN_TOKENS: u32 = 2_500;

/// Maximum character length for a tool result before truncation.
pub const TOOL_RESULT_MAX_CHARS: usize = 100_000;

// =============================================================================
// System Prompts
// =============================================================================

/// Maximum file size (bytes) for a user-provided SYSTEM.md prompt.
pub const MAX_SYSTEM_PROMPT_FILE_SIZE: u64 = 100 * 1024;

// =============================================================================
// LLM Summarizer
// =============================================================================

/// Maximum serialized character length for the summarizer transcript.
pub const SUMMARIZER_MAX_SERIALIZED_CHARS: usize = 150_000;

/// Truncation limit for assistant text blocks in the serialized transcript.
pub const SUMMARIZER_ASSISTANT_TEXT_LIMIT: usize = 300;

/// Truncation limit for thinking blocks in the serialized transcript.
pub const SUMMARIZER_THINKING_TEXT_LIMIT: usize = 500;

/// Truncation limit for tool result text in the serialized transcript.
pub const SUMMARIZER_TOOL_RESULT_TEXT_LIMIT: usize = 100;

/// Timeout for the summarizer subagent (milliseconds).
pub const SUMMARIZER_SUBAGENT_TIMEOUT_MS: u64 = 30_000;

// =============================================================================
// Compaction Engine
// =============================================================================

/// Prefix for the compacted summary user message.
pub const COMPACTION_SUMMARY_PREFIX: &str =
    "[Context from earlier in this conversation]";

/// Assistant acknowledgment text after compaction.
pub const COMPACTION_ACK_TEXT: &str =
    "I understand the previous context. Let me continue helping you.";

// =============================================================================
// Rules
// =============================================================================

/// Header prepended to rules content when injecting into context.
pub const RULES_HEADER: &str = "# Project Rules\n\n";

// =============================================================================
// Context Thresholds
// =============================================================================

/// Context usage threshold ratios for escalating warnings.
pub struct Thresholds;

impl Thresholds {
    /// 50% — yellow zone.
    pub const WARNING: f64 = 0.50;
    /// 70% — orange zone, suggest compaction.
    pub const ALERT: f64 = 0.70;
    /// 85% — red zone, block new turns.
    pub const CRITICAL: f64 = 0.85;
    /// 95% — hard limit.
    pub const EXCEEDED: f64 = 0.95;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chars_per_token_is_four() {
        assert_eq!(CHARS_PER_TOKEN, 4);
    }

    #[test]
    fn thresholds_are_ordered() {
        assert!(Thresholds::WARNING < Thresholds::ALERT);
        assert!(Thresholds::ALERT < Thresholds::CRITICAL);
        assert!(Thresholds::CRITICAL < Thresholds::EXCEEDED);
    }

    #[test]
    fn compaction_prefix_and_ack_non_empty() {
        assert!(!COMPACTION_SUMMARY_PREFIX.is_empty());
        assert!(!COMPACTION_ACK_TEXT.is_empty());
    }
}
