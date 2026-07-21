//! Context subsystem constants.
//!
//! Shared constants for the context manager and token estimator.

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
// Compaction Engine
// =============================================================================

/// Prefix for the compacted summary user message.
pub const COMPACTION_SUMMARY_PREFIX: &str = "[Context from earlier in this conversation]";

/// Assistant acknowledgment text after compaction.
pub const COMPACTION_ACK_TEXT: &str =
    "I understand the previous context. Let me continue helping you.";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chars_per_token_is_four() {
        assert_eq!(CHARS_PER_TOKEN, 4);
    }

    #[test]
    fn compaction_prefix_and_ack_non_empty() {
        assert!(!COMPACTION_SUMMARY_PREFIX.is_empty());
        assert!(!COMPACTION_ACK_TEXT.is_empty());
    }
}
