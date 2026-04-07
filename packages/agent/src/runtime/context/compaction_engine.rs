//! Compaction engine for managing context window limits.
//!
//! The [`CompactionEngine`] determines when compaction is needed, generates
//! previews, and executes compaction with summarization. It operates on
//! context state via injected dependencies ([`CompactionDeps`] trait),
//! enabling testability without coupling to [`crate::runtime::message_store`].
//!
//! ## Algorithm
//!
//! 1. Walk backward counting real user turns (skip compaction summaries).
//! 2. Stop when `preserve_recent_turns` reached or token budget exceeded.
//! 3. Apply orphaned-ToolResult fixup at the split boundary.
//! 4. Summarize older messages, replace with summary user + assistant ack.
//! 5. Report token counts and turn statistics.
//!
//! ## Compaction message format
//!
//! After compaction, the message list starts with:
//! ```text
//! [user]  "[Context from earlier in this conversation]\n\n<summary>"
//! [assistant] "I understand the previous context. Let me continue helping you."
//! ...preserved messages...
//! ```

use tracing::{instrument, trace};
use crate::core::content::AssistantContent;
use crate::core::messages::{Message, UserMessageContent};

use super::constants::{COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX};
use super::summarizer::Summarizer;
use super::types::{CompactionPreview, CompactionResult, ExtractedData};

// =============================================================================
// Dependencies trait
// =============================================================================

/// Injected dependencies from the context manager.
///
/// Allows the compaction engine to read/write context state without
/// direct coupling to `ContextManager` or `MessageStore`.
pub trait CompactionDeps: Send + Sync {
    /// Get a clone of all current messages.
    fn get_messages(&self) -> Vec<Message>;
    /// Replace all messages.
    fn set_messages(&self, messages: Vec<Message>);
    /// Get current total token count (API-reported or estimated).
    fn get_current_tokens(&self) -> u64;
    /// Get the model's context limit.
    fn get_context_limit(&self) -> u64;
    /// Estimate system prompt tokens.
    fn estimate_system_prompt_tokens(&self) -> u64;
    /// Estimate tools definition tokens.
    fn estimate_tools_tokens(&self) -> u64;
    /// Get estimated token count for a specific message.
    fn get_message_tokens(&self, msg: &Message) -> u64;
}

// =============================================================================
// CompactionEngine
// =============================================================================

/// Manages context compaction to stay within context window limits.
///
/// Uses turn-based preservation: keeps the last N user turns (each turn
/// being a user prompt plus all responses/tool-results until the next
/// user message), capped by a maximum token budget.
pub struct CompactionEngine<D: CompactionDeps> {
    /// Compaction threshold ratio (0–1).
    threshold: f64,
    /// Number of recent user turns to preserve.
    preserve_recent_turns: usize,
    /// Maximum ratio (0.0–1.0) of context limit for preserved messages.
    max_preserved_ratio: f64,
    /// Injected dependencies.
    pub(crate) deps: D,
    /// Callback for when compaction is needed.
    on_needed_callback: Option<Box<dyn Fn() + Send + Sync>>,
}

impl<D: CompactionDeps> CompactionEngine<D> {
    /// Create a new compaction engine.
    pub fn new(
        threshold: f64,
        preserve_recent_turns: usize,
        max_preserved_ratio: f64,
        deps: D,
    ) -> Self {
        Self {
            threshold,
            preserve_recent_turns,
            max_preserved_ratio,
            deps,
            on_needed_callback: None,
        }
    }

    /// Compute the index at which to split messages.
    /// Messages `[0..split)` are summarized, messages `[split..]` are preserved verbatim.
    ///
    /// Algorithm:
    /// 1. Walk backward from end counting real user turns (skip compaction summaries)
    /// 2. Stop when `preserve_recent_turns` reached OR token budget exceeded
    /// 3. Apply orphaned-`ToolResult` fixup (walk backward past `ToolResult`s at boundary)
    /// 4. Guarantee: if `preserve_recent_turns > 0` and there are messages,
    ///    preserve at least 1 complete turn
    fn compute_split_point(&self, messages: &[Message]) -> usize {
        if messages.is_empty() {
            return 0;
        }
        if self.preserve_recent_turns == 0 {
            return messages.len(); // summarize everything
        }

        #[allow(clippy::cast_precision_loss)]
        let token_budget =
            (self.max_preserved_ratio * self.deps.get_context_limit() as f64) as u64;

        let mut turns_seen: usize = 0;
        let mut candidate_split = messages.len(); // default: nothing preserved
        let mut preserved_tokens: u64 = 0;
        let mut current_turn_tokens: u64 = 0;

        // Walk backward through messages
        for i in (0..messages.len()).rev() {
            let msg_tokens = self.deps.get_message_tokens(&messages[i]);

            if messages[i].is_real_user_turn() {
                // This User message starts a new turn (going backward)
                current_turn_tokens += msg_tokens;

                // Check if this complete turn fits in the budget
                if preserved_tokens + current_turn_tokens > token_budget && turns_seen > 0 {
                    // This turn would exceed budget, stop here (keep previous turns)
                    break;
                }

                turns_seen += 1;
                preserved_tokens += current_turn_tokens;
                candidate_split = i;

                if turns_seen >= self.preserve_recent_turns {
                    break;
                }

                // Reset for next turn
                current_turn_tokens = 0;
            } else {
                // Assistant, ToolResult, or compaction summary — accumulate into current turn
                current_turn_tokens += msg_tokens;
            }
        }

        // If no real user turns were found, preserve everything (nothing to anchor on).
        // If we found fewer turns than requested AND no more turns exist before
        // the split point, preserve everything including non-turn messages.
        if turns_seen == 0 && self.preserve_recent_turns > 0 {
            candidate_split = 0;
        } else if turns_seen > 0 && turns_seen < self.preserve_recent_turns {
            let remaining_turns = messages[..candidate_split]
                .iter()
                .filter(|m| m.is_real_user_turn())
                .count();
            if remaining_turns == 0 {
                candidate_split = 0;
            }
        }

        // Orphaned ToolResult fixup: if split is within bounds and lands on a ToolResult,
        // walk backward to include its preceding Assistant
        if candidate_split < messages.len() {
            while candidate_split > 0 && messages[candidate_split].is_tool_result() {
                candidate_split -= 1;
            }
        }

        candidate_split
    }

    /// Count real user turns in a slice of messages.
    fn count_real_turns(messages: &[Message]) -> usize {
        messages.iter().filter(|m| m.is_real_user_turn()).count()
    }

    /// Check if compaction is recommended based on current token usage.
    #[must_use]
    pub fn should_compact(&self) -> bool {
        let limit = self.deps.get_context_limit();
        if limit == 0 {
            return false;
        }
        #[allow(clippy::cast_precision_loss)]
        let ratio = self.deps.get_current_tokens() as f64 / limit as f64;
        ratio >= self.threshold
    }

    /// Generate a compaction preview without modifying state.
    #[instrument(skip_all)]
    pub async fn preview(
        &self,
        summarizer: &dyn Summarizer,
    ) -> Result<CompactionPreview, Box<dyn std::error::Error + Send + Sync>> {
        let tokens_before = self.message_only_tokens();
        let messages = self.deps.get_messages();

        let split = self.compute_split_point(&messages);
        let to_summarize = &messages[..split];
        let preserved = &messages[split..];

        let summary_result = summarizer.summarize(to_summarize).await?;

        let tokens_after =
            self.estimate_tokens_after_compaction(&summary_result.narrative, preserved);

        let compression_ratio = if tokens_before > 0 {
            #[allow(clippy::cast_precision_loss)]
            {
                tokens_after as f64 / tokens_before as f64
            }
        } else {
            1.0
        };

        let preserved_turns = Self::count_real_turns(preserved);
        let summarized_turns = Self::count_real_turns(to_summarize);

        Ok(CompactionPreview {
            tokens_before,
            tokens_after,
            compression_ratio,
            preserved_messages: preserved.len(),
            summarized_messages: to_summarize.len(),
            preserved_turns,
            summarized_turns,
            summary: summary_result.narrative,
            extracted_data: Some(summary_result.extracted_data),
        })
    }

    /// Execute compaction and update messages.
    #[instrument(skip_all, fields(edited = edited_summary.is_some()))]
    pub async fn execute(
        &self,
        summarizer: &dyn Summarizer,
        edited_summary: Option<&str>,
    ) -> Result<CompactionResult, Box<dyn std::error::Error + Send + Sync>> {
        let tokens_before = self.message_only_tokens();
        let messages = self.deps.get_messages();

        let split = self.compute_split_point(&messages);
        let to_summarize = &messages[..split];
        let preserved = &messages[split..];

        // Nothing to summarize — conversation fits within preserve window
        if to_summarize.is_empty() {
            trace!(
                total_messages = messages.len(),
                "Compaction skipped: all messages within preserve window"
            );
            return Ok(CompactionResult {
                success: true,
                tokens_before,
                tokens_after: tokens_before,
                compression_ratio: 1.0,
                preserved_turns: Self::count_real_turns(preserved),
                summarized_turns: 0,
                preserved_messages: preserved.len(),
                summary: String::new(),
                extracted_data: None,
            });
        }

        let preserved_turns = Self::count_real_turns(preserved);
        let summarized_turns = Self::count_real_turns(to_summarize);

        trace!(
            total_messages = messages.len(),
            to_summarize = to_summarize.len(),
            to_preserve = preserved.len(),
            preserved_turns,
            summarized_turns,
            tokens_before,
            using_edited = edited_summary.is_some(),
            "Compaction: calling summarizer"
        );

        // Generate or use edited summary
        let summary: String;
        let mut extracted_data: Option<ExtractedData> = None;

        if let Some(edited) = edited_summary {
            summary = edited.to_owned();
        } else {
            let result = summarizer.summarize(to_summarize).await?;
            summary = result.narrative;
            extracted_data = Some(result.extracted_data);
        }

        trace!(
            summary_length = summary.len(),
            has_extracted_data = extracted_data.is_some(),
            "Compaction: summary generated"
        );

        // Build new message list
        let mut new_messages = Vec::with_capacity(2 + preserved.len());
        new_messages.push(Message::User {
            content: UserMessageContent::Text(format!("{COMPACTION_SUMMARY_PREFIX}\n\n{summary}")),
            timestamp: None,
        });
        new_messages.push(Message::Assistant {
            content: vec![AssistantContent::text(COMPACTION_ACK_TEXT)],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        });
        new_messages.extend_from_slice(preserved);

        let tokens_after = self.estimate_tokens_after_compaction(&summary, &new_messages[2..]);
        let compression_ratio = if tokens_before > 0 {
            #[allow(clippy::cast_precision_loss)]
            {
                tokens_after as f64 / tokens_before as f64
            }
        } else {
            1.0
        };

        // Update state
        self.deps.set_messages(new_messages);

        trace!(
            tokens_before,
            tokens_after,
            tokens_saved = tokens_before.saturating_sub(tokens_after),
            compression_ratio,
            preserved_turns,
            summarized_turns,
            "Compaction: complete"
        );

        Ok(CompactionResult {
            success: true,
            tokens_before,
            tokens_after,
            compression_ratio,
            preserved_turns,
            summarized_turns,
            preserved_messages: preserved.len(),
            summary,
            extracted_data,
        })
    }

    /// Register callback for when compaction is needed.
    pub fn on_needed(&mut self, callback: impl Fn() + Send + Sync + 'static) {
        self.on_needed_callback = Some(Box::new(callback));
    }

    /// Trigger callback if compaction is needed.
    pub fn trigger_if_needed(&self) {
        if self.should_compact()
            && let Some(cb) = &self.on_needed_callback
        {
            cb();
        }
    }

    // ─── Private helpers ─────────────────────────────────────────────────

    /// Calculate message-only tokens (total - system overhead - tools overhead).
    fn message_only_tokens(&self) -> u64 {
        let total = self.deps.get_current_tokens();
        let overhead =
            self.deps.estimate_system_prompt_tokens() + self.deps.estimate_tools_tokens();
        total.saturating_sub(overhead)
    }

    /// Estimate tokens after compaction.
    fn estimate_tokens_after_compaction(
        &self,
        summary: &str,
        preserved_messages: &[Message],
    ) -> u64 {
        #[allow(clippy::cast_possible_truncation)]
        let summary_tokens = summary.len().div_ceil(4) as u64;
        let context_message_tokens: u64 = 50; // Overhead for context wrapper
        let ack_message_tokens: u64 = 50; // Assistant acknowledgment

        let preserved_tokens: u64 = preserved_messages
            .iter()
            .map(|msg| self.deps.get_message_tokens(msg))
            .sum();

        summary_tokens + context_message_tokens + ack_message_tokens + preserved_tokens
    }
}

// =============================================================================
// Tests
// =============================================================================


#[cfg(test)]
#[path = "compaction_engine_tests.rs"]
mod tests;
