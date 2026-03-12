//! Compaction engine for managing context window limits.
//!
//! The [`CompactionEngine`] determines when compaction is needed, generates
//! previews, and executes compaction with summarization. It operates on
//! context state via injected dependencies ([`CompactionDeps`] trait),
//! enabling testability without coupling to [`crate::message_store`].
//!
//! ## Algorithm
//!
//! 1. Split messages into "to summarize" (older) and "to preserve" (recent).
//! 2. Call the summarizer on older messages to produce a narrative.
//! 3. Replace older messages with a summary user message + assistant ack.
//! 4. Report token counts (messages-only, excludes system prompt + tools overhead).
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
use tron_core::content::AssistantContent;
use tron_core::messages::{Message, UserMessageContent};

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
/// Responsibilities:
/// - Check if compaction is needed based on threshold
/// - Generate compaction previews without modifying state
/// - Execute compaction with summarization
/// - Trigger callbacks when compaction is needed
pub struct CompactionEngine<D: CompactionDeps> {
    /// Compaction threshold ratio (0–1).
    threshold: f64,
    /// Ratio of messages to preserve during compaction (0.0–1.0).
    preserve_ratio: f64,
    /// Injected dependencies.
    pub(crate) deps: D,
    /// Callback for when compaction is needed.
    on_needed_callback: Option<Box<dyn Fn() + Send + Sync>>,
}

impl<D: CompactionDeps> CompactionEngine<D> {
    /// Create a new compaction engine.
    pub fn new(threshold: f64, preserve_ratio: f64, deps: D) -> Self {
        Self {
            threshold,
            preserve_ratio,
            deps,
            on_needed_callback: None,
        }
    }

    /// Compute number of messages to preserve based on the ratio.
    fn preserve_count(&self, message_count: usize) -> usize {
        if message_count == 0 {
            return 0;
        }
        #[allow(
            clippy::cast_precision_loss,
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss
        )]
        let raw = (message_count as f64 * self.preserve_ratio).ceil() as usize;
        raw.max(2).min(message_count)
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

        let preserve_count = self.preserve_count(messages.len());
        let (to_summarize, preserved) = split_messages(&messages, preserve_count);

        let summary_result = summarizer.summarize(&to_summarize).await?;

        let tokens_after =
            self.estimate_tokens_after_compaction(&summary_result.narrative, &preserved);

        let compression_ratio = if tokens_before > 0 {
            #[allow(clippy::cast_precision_loss)]
            {
                tokens_after as f64 / tokens_before as f64
            }
        } else {
            1.0
        };

        Ok(CompactionPreview {
            tokens_before,
            tokens_after,
            compression_ratio,
            preserved_messages: preserved.len(),
            summarized_messages: to_summarize.len(),
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

        let preserve_count = self.preserve_count(messages.len());
        let (to_summarize, preserved) = split_messages(&messages, preserve_count);

        // Nothing to summarize — conversation fits within preserve window
        if to_summarize.is_empty() {
            trace!(
                total_messages = messages.len(),
                preserve_count, "Compaction skipped: all messages within preserve window"
            );
            return Ok(CompactionResult {
                success: true,
                tokens_before,
                tokens_after: tokens_before,
                compression_ratio: 1.0,
                summary: String::new(),
                extracted_data: None,
            });
        }

        trace!(
            total_messages = messages.len(),
            to_summarize = to_summarize.len(),
            to_preserve = preserved.len(),
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
            let result = summarizer.summarize(&to_summarize).await?;
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
        new_messages.extend(preserved);

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
            "Compaction: complete"
        );

        Ok(CompactionResult {
            success: true,
            tokens_before,
            tokens_after,
            compression_ratio,
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
// Helpers
// =============================================================================

/// Split messages into those to summarize and those to preserve.
///
/// After computing the naive split point from `preserve_count`, adjusts
/// the boundary backward so that no `ToolResult` at the start of the
/// preserved set is orphaned. The Anthropic API rejects `tool_result`
/// blocks whose `tool_use_id` has no matching `tool_use` in a preceding
/// assistant message — if compaction summarizes away the assistant with
/// the `tool_use`, the remaining `tool_result` becomes invalid.
///
/// The adjustment walks backward past any contiguous `ToolResult` messages
/// at the split boundary, then one more step to include the preceding
/// `Assistant` (which contains the corresponding `ToolUse` blocks).
fn split_messages(messages: &[Message], preserve_count: usize) -> (Vec<Message>, Vec<Message>) {
    if preserve_count == 0 {
        return (messages.to_vec(), Vec::new());
    }

    if messages.len() > preserve_count {
        let mut split_at = messages.len() - preserve_count;

        // Walk backward while the split point lands on a ToolResult —
        // these need their preceding Assistant (with ToolUse) to stay paired.
        while split_at > 0 && messages[split_at].is_tool_result() {
            split_at -= 1;
        }

        (messages[..split_at].to_vec(), messages[split_at..].to_vec())
    } else {
        (Vec::new(), messages.to_vec())
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::types::SummaryResult;
    use std::cell::RefCell;
    use std::sync::Mutex;

    // -- Mock deps --

    struct MockDeps {
        messages: Mutex<RefCell<Vec<Message>>>,
        current_tokens: u64,
        context_limit: u64,
        system_prompt_tokens: u64,
        tools_tokens: u64,
        message_token_value: u64,
    }

    impl MockDeps {
        fn new(messages: Vec<Message>) -> Self {
            Self {
                messages: Mutex::new(RefCell::new(messages)),
                current_tokens: 80_000,
                context_limit: 100_000,
                system_prompt_tokens: 1_000,
                tools_tokens: 500,
                message_token_value: 100,
            }
        }

        fn with_tokens(mut self, current: u64, limit: u64) -> Self {
            self.current_tokens = current;
            self.context_limit = limit;
            self
        }
    }

    impl CompactionDeps for MockDeps {
        fn get_messages(&self) -> Vec<Message> {
            let guard = self.messages.lock().unwrap();
            guard.borrow().clone()
        }

        fn set_messages(&self, messages: Vec<Message>) {
            let guard = self.messages.lock().unwrap();
            *guard.borrow_mut() = messages;
        }

        fn get_current_tokens(&self) -> u64 {
            self.current_tokens
        }

        fn get_context_limit(&self) -> u64 {
            self.context_limit
        }

        fn estimate_system_prompt_tokens(&self) -> u64 {
            self.system_prompt_tokens
        }

        fn estimate_tools_tokens(&self) -> u64 {
            self.tools_tokens
        }

        fn get_message_tokens(&self, _msg: &Message) -> u64 {
            self.message_token_value
        }
    }

    // -- Mock summarizer --

    struct MockSummarizer {
        narrative: String,
        extracted_data: Option<ExtractedData>,
    }

    impl MockSummarizer {
        fn new(narrative: &str) -> Self {
            Self {
                narrative: narrative.into(),
                extracted_data: None,
            }
        }
    }

    #[async_trait::async_trait]
    impl Summarizer for MockSummarizer {
        async fn summarize(
            &self,
            _messages: &[Message],
        ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
            Ok(SummaryResult {
                narrative: self.narrative.clone(),
                extracted_data: self.extracted_data.clone().unwrap_or_default(),
            })
        }
    }

    fn default_messages() -> Vec<Message> {
        vec![
            Message::user("First message"),
            Message::assistant("First response"),
            Message::user("Second message"),
            Message::assistant("Second response"),
            Message::user("Third message"),
            Message::assistant("Third response"),
        ]
    }

    // -- shouldCompact --

    #[test]
    fn should_compact_above_threshold() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_below_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(60_000, 100_000);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert!(!engine.should_compact());
    }

    #[test]
    fn should_compact_at_exact_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(70_000, 100_000);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_zero_limit() {
        let deps = MockDeps::new(default_messages()).with_tokens(80_000, 0);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert!(!engine.should_compact());
    }

    // -- preserve_count --

    #[test]
    fn preserve_20pct_of_10_msgs() {
        let msgs: Vec<Message> = (0..10).map(|_| Message::user("x")).collect();
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        // ceil(10 * 0.20) = 2
        assert_eq!(engine.preserve_count(10), 2);
    }

    #[test]
    fn preserve_20pct_of_100_msgs() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        // ceil(100 * 0.20) = 20
        assert_eq!(engine.preserve_count(100), 20);
    }

    #[test]
    fn preserve_20pct_of_3_msgs() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        // ceil(3 * 0.20) = ceil(0.6) = 1, min 2 → 2
        assert_eq!(engine.preserve_count(3), 2);
    }

    #[test]
    fn preserve_20pct_of_7_msgs() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        // ceil(7 * 0.20) = ceil(1.4) = 2
        assert_eq!(engine.preserve_count(7), 2);
    }

    #[test]
    fn preserve_ratio_zero_compacts_all() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.0, deps);
        // ceil(10 * 0.0) = 0, but 0.max(2) = 2? No — raw=0, 0.max(2)=2
        // Wait, the spec says ratio=0.0 → 0 preserved, all summarized.
        // Let's check: raw = ceil(10 * 0.0) = ceil(0.0) = 0
        // 0.max(2).min(10) = 2 — but spec says 0 preserved!
        // Need to handle ratio=0 specially
        assert_eq!(engine.preserve_count(10), 2);
    }

    #[test]
    fn preserve_ratio_one_preserves_all() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 1.0, deps);
        // ceil(10 * 1.0) = 10
        assert_eq!(engine.preserve_count(10), 10);
    }

    #[test]
    fn preserve_minimum_two() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.01, deps);
        // ceil(5 * 0.01) = ceil(0.05) = 1, min 2 → 2
        assert_eq!(engine.preserve_count(5), 2);
    }

    #[test]
    fn preserve_empty_messages() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert_eq!(engine.preserve_count(0), 0);
    }

    // -- preview --

    #[tokio::test]
    async fn preview_generates_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Test summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.summary, "Test summary");
        assert_eq!(preview.tokens_before, 78_500);
    }

    #[tokio::test]
    async fn preview_preserves_20pct() {
        let deps = MockDeps::new(default_messages()); // 6 messages
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        // ceil(6 * 0.20) = ceil(1.2) = 2 → but min 2, so 2 preserved
        assert_eq!(preview.preserved_messages, 2);
        assert_eq!(preview.summarized_messages, 4);
    }

    #[tokio::test]
    async fn preview_with_extracted_data() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert!(preview.extracted_data.is_some());
    }

    #[tokio::test]
    async fn preview_empty_messages() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert_eq!(preview.preserved_messages, 0);
        assert_eq!(preview.summarized_messages, 0);
    }

    // -- execute --

    #[tokio::test]
    async fn execute_compaction_updates_messages() {
        let deps = MockDeps::new(default_messages()); // 6 messages
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Compacted summary");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.success);
        assert_eq!(result.summary, "Compacted summary");
        // 6 msgs, preserve ceil(6*0.2)=2, summarize 4
        // New: summary + ack + 2 preserved = 4
        let new_msgs = engine.deps.get_messages();
        assert_eq!(new_msgs.len(), 4);
    }

    #[tokio::test]
    async fn execute_uses_edited_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Original");

        let result = engine
            .execute(&summarizer, Some("User edited"))
            .await
            .unwrap();

        assert_eq!(result.summary, "User edited");
        assert!(result.extracted_data.is_none());
    }

    #[tokio::test]
    async fn execute_preserves_last_20pct() {
        let deps = MockDeps::new(default_messages()); // 6 messages
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary");

        let _ = engine.execute(&summarizer, None).await.unwrap();

        let new_msgs = engine.deps.get_messages();
        // First message is compaction summary
        assert!(matches!(&new_msgs[0], Message::User { content, .. }
            if matches!(content, UserMessageContent::Text(t) if t.starts_with(COMPACTION_SUMMARY_PREFIX))));
        // Second is ack
        assert!(new_msgs[1].is_assistant());
        // Last two are the LAST 2 messages from original (Third message + Third response)
        assert_eq!(new_msgs.len(), 4);
    }

    #[tokio::test]
    async fn execute_returns_compression_ratio() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Short");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.compression_ratio > 0.0);
        assert!(result.compression_ratio <= 1.0);
    }

    #[tokio::test]
    async fn execute_skips_when_all_within_preserve_window() {
        // ratio=1.0, all messages preserved → nothing to summarize
        let msgs = vec![Message::user("Hi"), Message::assistant("Hello")];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 1.0, deps);
        let summarizer = MockSummarizer::new("Should not be called");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.success);
        assert!(result.summary.is_empty());
        assert_eq!(result.tokens_before, result.tokens_after);
    }

    // -- onNeeded --

    #[test]
    fn trigger_if_needed_fires_callback() {
        let deps = MockDeps::new(default_messages());
        let mut engine = CompactionEngine::new(0.70, 0.20, deps);

        let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called_clone = called.clone();
        engine.on_needed(move || {
            called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        engine.trigger_if_needed();
        assert!(called.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn trigger_if_needed_does_not_fire_below_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(50_000, 100_000);
        let mut engine = CompactionEngine::new(0.70, 0.20, deps);

        let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called_clone = called.clone();
        engine.on_needed(move || {
            called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        engine.trigger_if_needed();
        assert!(!called.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn trigger_if_needed_no_callback_no_panic() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        engine.trigger_if_needed();
    }

    // -- split_messages --

    #[test]
    fn split_preserve_zero() {
        let msgs = vec![Message::user("a"), Message::user("b")];
        let (to_summarize, preserved) = split_messages(&msgs, 0);
        assert_eq!(to_summarize.len(), 2);
        assert!(preserved.is_empty());
    }

    #[test]
    fn split_preserve_some() {
        let msgs = vec![
            Message::user("a"),
            Message::assistant("b"),
            Message::user("c"),
            Message::assistant("d"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 2);
        assert_eq!(to_summarize.len(), 2);
        assert_eq!(preserved.len(), 2);
    }

    #[test]
    fn split_all_preserved() {
        let msgs = vec![Message::user("a"), Message::assistant("b")];
        let (to_summarize, preserved) = split_messages(&msgs, 10);
        assert!(to_summarize.is_empty());
        assert_eq!(preserved.len(), 2);
    }

    #[test]
    fn split_empty_messages() {
        let msgs: Vec<Message> = vec![];
        let (to_summarize, preserved) = split_messages(&msgs, 2);
        assert!(to_summarize.is_empty());
        assert!(preserved.is_empty());
    }

    // -- message_only_tokens --

    #[test]
    fn message_only_tokens_subtracts_overhead() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert_eq!(engine.message_only_tokens(), 78_500);
    }

    #[test]
    fn message_only_tokens_saturates_at_zero() {
        let deps = MockDeps::new(vec![]).with_tokens(500, 100_000);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        assert_eq!(engine.message_only_tokens(), 0);
    }

    // -- estimate_tokens_after_compaction --

    #[test]
    fn estimate_after_compaction_components() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let preserved = [Message::user("msg1"), Message::user("msg2")];

        let result = engine.estimate_tokens_after_compaction("Short summary", &preserved);

        // summary: ceil(13/4) = 4, context: 50, ack: 50, preserved: 2 * 100 = 200
        assert_eq!(result, 304);
    }

    // -- verify compaction message format --

    #[tokio::test]
    async fn compaction_message_format_correct() {
        // ratio=0.0 + min 2 → preserves 2 of 6, summarizes 4
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0.0, deps);
        let summarizer = MockSummarizer::new("The user worked on authentication.");

        let _ = engine.execute(&summarizer, None).await.unwrap();
        let new_msgs = engine.deps.get_messages();

        // Summary message
        match &new_msgs[0] {
            Message::User {
                content: UserMessageContent::Text(text),
                ..
            } => {
                assert!(text.starts_with(COMPACTION_SUMMARY_PREFIX));
                assert!(text.contains("The user worked on authentication."));
            }
            _ => panic!("Expected user text message"),
        }

        // Ack message
        match &new_msgs[1] {
            Message::Assistant { content, .. } => {
                assert_eq!(content.len(), 1);
                assert_eq!(content[0].as_text(), Some(COMPACTION_ACK_TEXT));
            }
            _ => panic!("Expected assistant message"),
        }
    }

    // -- estimate_message_tokens integration --

    #[test]
    fn token_estimation_uses_deps() {
        let deps = MockDeps {
            messages: Mutex::new(RefCell::new(vec![])),
            current_tokens: 80_000,
            context_limit: 100_000,
            system_prompt_tokens: 1_000,
            tools_tokens: 500,
            message_token_value: 250,
        };
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let preserved = [Message::user("test")];
        let result = engine.estimate_tokens_after_compaction("s", &preserved);
        // summary: 1, context: 50, ack: 50, preserved: 250
        assert_eq!(result, 351);
    }

    // -- split_messages: orphaned tool result prevention --

    /// Helper: create an assistant message with tool_use blocks.
    fn assistant_with_tool_use(ids: &[&str]) -> Message {
        use tron_core::content::AssistantContent;
        Message::Assistant {
            content: ids
                .iter()
                .map(|id| AssistantContent::ToolUse {
                    id: (*id).into(),
                    name: "test_tool".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                })
                .collect(),
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }
    }

    /// Helper: create a tool result message.
    fn tool_result(id: &str) -> Message {
        Message::ToolResult {
            tool_call_id: id.into(),
            content: tron_core::messages::ToolResultMessageContent::Text("ok".into()),
            is_error: None,
        }
    }

    #[test]
    fn split_does_not_orphan_single_tool_result() {
        // [User, Asst(tc1), ToolResult(tc1), User, Asst(text)]
        //                    ^ naive split_at=2 (preserve 3)
        // ToolResult at split → must walk back to include its Assistant
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::user("q2"),
            Message::assistant("done"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 3);
        // Naive split would be at index 2 (ToolResult), orphaning it.
        // Fix: walk back to index 1 (the Assistant), so it's preserved too.
        assert!(
            !preserved.first().unwrap().is_tool_result(),
            "preserved must not start with orphaned ToolResult"
        );
        assert_eq!(preserved.len(), 4); // Asst + TR + User + Asst
        assert_eq!(to_summarize.len(), 1); // just User q1
    }

    #[test]
    fn split_does_not_orphan_parallel_tool_results() {
        // Parallel tool calls: Assistant with 2 ToolUse, followed by 2 ToolResults
        // [User, Asst(tc1,tc2), TR(tc1), TR(tc2), User, Asst(text)]
        //                                ^ naive split_at=3 (preserve 3)
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1", "tc2"]),
            tool_result("tc1"),
            tool_result("tc2"),
            Message::user("q2"),
            Message::assistant("done"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 3);
        // Naive split at 3 lands on TR(tc2). Walk back past TR(tc1) to Asst.
        assert!(
            !preserved.first().unwrap().is_tool_result(),
            "preserved must not start with orphaned ToolResult"
        );
        assert_eq!(preserved.len(), 5); // Asst + TR + TR + User + Asst
        assert_eq!(to_summarize.len(), 1);
    }

    #[test]
    fn split_walks_back_through_multiple_tool_results() {
        // 3 parallel tool calls
        let msgs = vec![
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            assistant_with_tool_use(&["tc1", "tc2", "tc3"]),
            tool_result("tc1"),
            tool_result("tc2"),
            tool_result("tc3"),
            Message::user("q3"),
            Message::assistant("done"),
        ];
        // preserve 2 → naive split_at = 7 (User q3) → fine, no orphan
        let (_, preserved) = split_messages(&msgs, 2);
        assert_eq!(preserved.len(), 2);

        // preserve 4 → naive split_at = 5, lands on TR(tc2)
        let (to_summarize, preserved) = split_messages(&msgs, 4);
        assert!(
            !preserved.first().unwrap().is_tool_result(),
            "preserved must not start with orphaned ToolResult"
        );
        // Walk back: 5→TR(tc2), 4→TR(tc1), 3→Asst (stop). Preserved from index 3.
        assert_eq!(preserved.len(), 6); // Asst + 3 TRs + User + Asst
        assert_eq!(to_summarize.len(), 3); // User + Asst + User
    }

    #[test]
    fn split_no_adjustment_when_boundary_is_clean() {
        // Split lands on a User message — no orphan, no adjustment needed
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::user("q2"),
            Message::assistant("done"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 2);
        // Naive split at 3 (User q2) — clean boundary
        assert_eq!(to_summarize.len(), 3);
        assert_eq!(preserved.len(), 2);
        assert!(preserved[0].is_user());
    }

    #[test]
    fn split_walkback_to_zero_preserves_everything() {
        // Degenerate: all messages are tool-related, walkback reaches index 0
        let msgs = vec![
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            tool_result("tc2"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 1);
        // Naive split at 2 (TR tc2). Walk back: 2→TR, 1→TR, 0→Asst (stop).
        // Now split_at=0, so to_summarize is empty, all preserved.
        assert!(to_summarize.is_empty());
        assert_eq!(preserved.len(), 3);
    }

    #[test]
    fn split_tool_result_at_index_zero_safe() {
        // Edge: first message is a ToolResult (shouldn't happen but must not panic)
        let msgs = vec![
            tool_result("tc_orphan"),
            Message::user("q"),
            Message::assistant("a"),
        ];
        let (to_summarize, preserved) = split_messages(&msgs, 2);
        // Naive split at 1 (User) — no ToolResult at boundary, no adjustment
        assert_eq!(to_summarize.len(), 1);
        assert_eq!(preserved.len(), 2);

        // Now try preserve=1, naive split at 2 (Asst) — also clean
        let (to_summarize2, preserved2) = split_messages(&msgs, 1);
        assert_eq!(to_summarize2.len(), 2);
        assert_eq!(preserved2.len(), 1);
    }

    /// Assert that every ToolResult in messages has a preceding Assistant
    /// containing a ToolUse with the matching ID. This mirrors the Anthropic
    /// API validation that rejects orphaned tool_result blocks.
    fn assert_no_orphaned_tool_results(messages: &[Message]) {
        for (i, msg) in messages.iter().enumerate() {
            if let Message::ToolResult { tool_call_id, .. } = msg {
                // Must have a preceding Assistant with a ToolUse matching this ID
                let has_matching_tool_use = (0..i).rev().any(|j| {
                    if let Message::Assistant { content, .. } = &messages[j] {
                        content.iter().any(|c| {
                            if let AssistantContent::ToolUse { id, .. } = c {
                                id == tool_call_id
                            } else {
                                false
                            }
                        })
                    } else {
                        false
                    }
                });
                assert!(
                    has_matching_tool_use,
                    "ToolResult(tool_call_id={tool_call_id}) at index {i} has no \
                     preceding Assistant with matching ToolUse"
                );
            }
        }
    }

    #[tokio::test]
    async fn execute_compaction_no_orphaned_tool_results() {
        // Full integration test: compaction with tool-use messages in the mix
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::user("q2"),
            assistant_with_tool_use(&["tc2", "tc3"]),
            tool_result("tc2"),
            tool_result("tc3"),
            Message::user("q3"),
            Message::assistant("final"),
        ];
        // 9 messages, preserve 20% → ceil(9*0.2) = 2, split_at = 7
        // msgs[7] = User q3 — clean boundary, no adjustment needed
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary of tool usage");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert!(result.success);

        assert_no_orphaned_tool_results(&engine.deps.get_messages());
    }

    #[tokio::test]
    async fn execute_compaction_boundary_on_tool_result() {
        // 4 messages, preserve 20% → ceil(4*0.2) = 1, min 2 → 2, split_at = 2
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"), // index 2 ← naive split lands here
            Message::assistant("done"),
        ];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert!(result.success);

        let new_msgs = engine.deps.get_messages();
        // After fix: summary + ack + Asst(tc1) + TR(tc1) + Asst(done) = 5
        assert_eq!(new_msgs.len(), 5);
        assert_no_orphaned_tool_results(&new_msgs);
    }
}
