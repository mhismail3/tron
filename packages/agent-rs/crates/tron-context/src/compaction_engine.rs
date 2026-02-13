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

use tron_core::content::AssistantContent;
use tron_core::messages::{Message, UserMessageContent};
use tracing::{info, trace};

use crate::constants::{COMPACTION_ACK_TEXT, COMPACTION_SUMMARY_PREFIX};
use crate::summarizer::Summarizer;
use crate::types::{CompactionPreview, CompactionResult, ExtractedData};

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
    /// Number of recent turns to preserve during compaction.
    preserve_recent_turns: usize,
    /// Injected dependencies.
    pub(crate) deps: D,
    /// Callback for when compaction is needed.
    on_needed_callback: Option<Box<dyn Fn() + Send + Sync>>,
}

impl<D: CompactionDeps> CompactionEngine<D> {
    /// Create a new compaction engine.
    pub fn new(threshold: f64, preserve_recent_turns: usize, deps: D) -> Self {
        Self {
            threshold,
            preserve_recent_turns,
            deps,
            on_needed_callback: None,
        }
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
    pub async fn preview(
        &self,
        summarizer: &dyn Summarizer,
    ) -> Result<CompactionPreview, Box<dyn std::error::Error + Send + Sync>> {
        let tokens_before = self.message_only_tokens();
        let messages = self.deps.get_messages();

        let preserve_count = self.preserve_recent_turns * 2;
        let (to_summarize, preserved) = split_messages(&messages, preserve_count);

        let summary_result = summarizer.summarize(&to_summarize).await?;

        let tokens_after =
            self.estimate_tokens_after_compaction(&summary_result.narrative, &preserved);

        let compression_ratio = if tokens_before > 0 {
            #[allow(clippy::cast_precision_loss)]
            { tokens_after as f64 / tokens_before as f64 }
        } else {
            1.0
        };

        Ok(CompactionPreview {
            tokens_before,
            tokens_after,
            compression_ratio,
            preserved_turns: self.preserve_recent_turns,
            summarized_turns: to_summarize.len() / 2,
            summary: summary_result.narrative,
            extracted_data: Some(summary_result.extracted_data),
        })
    }

    /// Execute compaction and update messages.
    pub async fn execute(
        &self,
        summarizer: &dyn Summarizer,
        edited_summary: Option<&str>,
    ) -> Result<CompactionResult, Box<dyn std::error::Error + Send + Sync>> {
        let tokens_before = self.message_only_tokens();
        let messages = self.deps.get_messages();

        let preserve_count = self.preserve_recent_turns * 2;
        let (to_summarize, preserved) = split_messages(&messages, preserve_count);

        // Nothing to summarize — conversation fits within preserve window
        if to_summarize.is_empty() {
            info!(
                total_messages = messages.len(),
                preserve_count,
                "Compaction skipped: all messages within preserve window"
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
            content: UserMessageContent::Text(format!(
                "{COMPACTION_SUMMARY_PREFIX}\n\n{summary}"
            )),
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
            { tokens_after as f64 / tokens_before as f64 }
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
        if self.should_compact() {
            if let Some(cb) = &self.on_needed_callback {
                cb();
            }
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
fn split_messages(messages: &[Message], preserve_count: usize) -> (Vec<Message>, Vec<Message>) {
    if preserve_count == 0 {
        return (messages.to_vec(), Vec::new());
    }

    if messages.len() > preserve_count {
        let split_at = messages.len() - preserve_count;
        (
            messages[..split_at].to_vec(),
            messages[split_at..].to_vec(),
        )
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
    use crate::types::SummaryResult;
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
        let engine = CompactionEngine::new(0.70, 1, deps);
        // 80000 / 100000 = 0.80 >= 0.70
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_below_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(60_000, 100_000);
        let engine = CompactionEngine::new(0.70, 1, deps);
        // 60000 / 100000 = 0.60 < 0.70
        assert!(!engine.should_compact());
    }

    #[test]
    fn should_compact_at_exact_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(70_000, 100_000);
        let engine = CompactionEngine::new(0.70, 1, deps);
        // 70000 / 100000 = 0.70 >= 0.70
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_zero_limit() {
        let deps = MockDeps::new(default_messages()).with_tokens(80_000, 0);
        let engine = CompactionEngine::new(0.70, 1, deps);
        assert!(!engine.should_compact());
    }

    // -- preview --

    #[tokio::test]
    async fn preview_generates_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Test summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.summary, "Test summary");
        // tokensBefore = 80000 - 1000 - 500 = 78500
        assert_eq!(preview.tokens_before, 78_500);
    }

    #[tokio::test]
    async fn preview_preserves_recent_turns() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.preserved_turns, 1);
        // 6 messages - 2 preserved = 4 summarized = 2 turns
        assert_eq!(preview.summarized_turns, 2);
    }

    #[tokio::test]
    async fn preview_with_extracted_data() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert!(preview.extracted_data.is_some());
    }

    #[tokio::test]
    async fn preview_empty_messages() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert_eq!(preview.preserved_turns, 1);
        assert_eq!(preview.summarized_turns, 0);
    }

    // -- execute --

    #[tokio::test]
    async fn execute_compaction_updates_messages() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Compacted summary");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.success);
        assert_eq!(result.summary, "Compacted summary");
        // Messages should be updated: summary + ack + 2 preserved = 4
        let new_msgs = engine.deps.get_messages();
        assert_eq!(new_msgs.len(), 4);
    }

    #[tokio::test]
    async fn execute_uses_edited_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Original");

        let result = engine
            .execute(&summarizer, Some("User edited"))
            .await
            .unwrap();

        assert_eq!(result.summary, "User edited");
        assert!(result.extracted_data.is_none());
    }

    #[tokio::test]
    async fn execute_preserves_recent_messages() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Summary");

        let _ = engine.execute(&summarizer, None).await.unwrap();

        let new_msgs = engine.deps.get_messages();
        // First message is compaction summary
        assert!(matches!(&new_msgs[0], Message::User { content, .. }
            if matches!(content, UserMessageContent::Text(t) if t.starts_with(COMPACTION_SUMMARY_PREFIX))));
        // Second is ack
        assert!(new_msgs[1].is_assistant());
        // Last two are preserved
        assert_eq!(new_msgs.len(), 4);
    }

    #[tokio::test]
    async fn execute_returns_compression_ratio() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, deps);
        let summarizer = MockSummarizer::new("Short");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.compression_ratio > 0.0);
        assert!(result.compression_ratio <= 1.0);
    }

    #[tokio::test]
    async fn execute_skips_when_all_within_preserve_window() {
        // Only 2 messages, preserveRecentTurns=5 → 10 messages to preserve > 2
        let msgs = vec![Message::user("Hi"), Message::assistant("Hello")];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 5, deps);
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
        let mut engine = CompactionEngine::new(0.70, 1, deps);

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
        let mut engine = CompactionEngine::new(0.70, 1, deps);

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
        let engine = CompactionEngine::new(0.70, 1, deps);
        // Should not panic
        engine.trigger_if_needed();
    }

    // -- preserveRecentTurns --

    #[tokio::test]
    async fn preserve_multiple_turns() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 2, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.preserved_turns, 2);
        // 6 - 4 preserved = 2 summarized = 1 turn
        assert_eq!(preview.summarized_turns, 1);
    }

    #[tokio::test]
    async fn preserve_zero_turns() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.preserved_turns, 0);
        assert_eq!(preview.summarized_turns, 3);
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
        let engine = CompactionEngine::new(0.70, 1, deps);
        // 80000 - 1000 - 500 = 78500
        assert_eq!(engine.message_only_tokens(), 78_500);
    }

    #[test]
    fn message_only_tokens_saturates_at_zero() {
        let deps = MockDeps::new(vec![]).with_tokens(500, 100_000);
        let engine = CompactionEngine::new(0.70, 1, deps);
        // 500 - 1000 - 500 would underflow, saturates to 0
        assert_eq!(engine.message_only_tokens(), 0);
    }

    // -- estimate_tokens_after_compaction --

    #[test]
    fn estimate_after_compaction_components() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 1, deps);
        let preserved = [Message::user("msg1"), Message::user("msg2")];

        let result = engine.estimate_tokens_after_compaction("Short summary", &preserved);

        // summary: ceil(13/4) = 4, context: 50, ack: 50, preserved: 2 * 100 = 200
        // Total: 4 + 50 + 50 + 200 = 304
        assert_eq!(result, 304);
    }

    // -- verify compaction message format --

    #[tokio::test]
    async fn compaction_message_format_correct() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0, deps);
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
        let engine = CompactionEngine::new(0.70, 1, deps);
        let preserved = [Message::user("test")];
        let result = engine.estimate_tokens_after_compaction("s", &preserved);
        // summary: 1, context: 50, ack: 50, preserved: 250
        assert_eq!(result, 351);
    }
}
