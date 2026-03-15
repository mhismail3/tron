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
mod tests {
    use super::*;
    use crate::runtime::context::types::SummaryResult;
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
        /// Optional token function for per-message token values.
        token_fn: Option<Box<dyn Fn(&Message) -> u64 + Send + Sync>>,
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
                token_fn: None,
            }
        }

        fn with_tokens(mut self, current: u64, limit: u64) -> Self {
            self.current_tokens = current;
            self.context_limit = limit;
            self
        }

        fn with_token_fn(
            mut self,
            f: impl Fn(&Message) -> u64 + Send + Sync + 'static,
        ) -> Self {
            self.token_fn = Some(Box::new(f));
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

        fn get_message_tokens(&self, msg: &Message) -> u64 {
            if let Some(f) = &self.token_fn {
                return f(msg);
            }
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

    /// Helper: create an assistant message with `tool_use` blocks.
    fn assistant_with_tool_use(ids: &[&str]) -> Message {
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
            content: crate::core::messages::ToolResultMessageContent::Text("ok".into()),
            is_error: None,
        }
    }

    /// Helper: create a compaction summary message.
    fn compaction_summary(text: &str) -> Message {
        Message::user(format!("{COMPACTION_SUMMARY_PREFIX}\n\n{text}"))
    }

    // ========================================================================
    // shouldCompact
    // ========================================================================

    #[test]
    fn should_compact_above_threshold() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_below_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(60_000, 100_000);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert!(!engine.should_compact());
    }

    #[test]
    fn should_compact_at_exact_threshold() {
        let deps = MockDeps::new(default_messages()).with_tokens(70_000, 100_000);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert!(engine.should_compact());
    }

    #[test]
    fn should_compact_zero_limit() {
        let deps = MockDeps::new(default_messages()).with_tokens(80_000, 0);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert!(!engine.should_compact());
    }

    // ========================================================================
    // compute_split_point — Category 1: Basic turn counting
    // ========================================================================

    #[test]
    fn basic_3_turns_preserve_2() {
        // [U,A,U,A,U,A] — 3 turns, preserve 2
        let msgs = default_messages();
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 2); // preserve [U,A,U,A] = last 2 turns
    }

    #[test]
    fn basic_5_turns_preserve_3() {
        let msgs: Vec<Message> = (0..10)
            .map(|i| {
                if i % 2 == 0 {
                    Message::user(format!("Q{}", i / 2))
                } else {
                    Message::assistant(format!("A{}", i / 2))
                }
            })
            .collect();
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 3, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 4); // preserve last 6 messages (3 turns)
    }

    #[test]
    fn basic_preserve_all() {
        // [U,A,U,A] — 2 turns, preserve 5 (more than available)
        let msgs = vec![
            Message::user("a"),
            Message::assistant("b"),
            Message::user("c"),
            Message::assistant("d"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 5, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // preserve everything
    }

    #[test]
    fn basic_single_turn() {
        let msgs = vec![Message::user("hi"), Message::assistant("hello")];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // 1 turn, preserve it all
    }

    #[test]
    fn basic_preserve_zero() {
        let msgs = default_messages();
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 0, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 6); // summarize all
    }

    // ========================================================================
    // compute_split_point — Category 2: Tool-heavy turns
    // ========================================================================

    #[test]
    fn tool_heavy_single_turn() {
        // [U, A(tc), TR, A(tc), TR, A(text)] — 1 turn = 6 messages
        let msgs = vec![
            Message::user("do stuff"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            assistant_with_tool_use(&["tc2"]),
            tool_result("tc2"),
            Message::assistant("done"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // 1 turn, preserve all
    }

    #[test]
    fn tool_heavy_preserve_1_of_2() {
        // [U,A, U,A(tc),TR,TR,A] — 2 turns, preserve 1
        let msgs = vec![
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            assistant_with_tool_use(&["tc2", "tc3"]),
            tool_result("tc2"),
            tool_result("tc3"),
            Message::assistant("done"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 2); // Last turn starts at U[2]
    }

    #[test]
    fn parallel_tools_one_turn() {
        // [U, A(tc1,tc2), TR1, TR2, A] — 1 turn
        let msgs = vec![
            Message::user("do both"),
            assistant_with_tool_use(&["tc1", "tc2"]),
            tool_result("tc1"),
            tool_result("tc2"),
            Message::assistant("done"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // 1 turn, preserve all
    }

    #[test]
    fn mixed_tool_and_simple() {
        // [U,A, U,A(tc),TR,A, U,A] — 3 turns, preserve 2
        let msgs = vec![
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::assistant("done tool"),
            Message::user("q3"),
            Message::assistant("r3"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 2); // Last 2 turns: [q2,A(tc),TR,A, q3,r3]
    }

    // ========================================================================
    // compute_split_point — Category 3: Token cap
    // ========================================================================

    #[test]
    fn token_cap_limits_turns() {
        // 3 turns, 500 tok per message, budget fits 2 turns
        let msgs = default_messages(); // 6 msgs, 3 turns
        let deps = MockDeps::new(msgs.clone())
            .with_tokens(80_000, 10_000)
            .with_token_fn(|_| 500);
        // budget = 0.20 * 10_000 = 2000. Each turn = 1000 tokens.
        // Turn 3 (last): 1000 ≤ 2000 → fits. Turn 2: 1000+1000=2000 ≤ 2000 → fits.
        // Turn 1: 1000+2000=3000 > 2000 and turns_seen=2 > 0 → stop.
        let engine = CompactionEngine::new(0.70, 3, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 2); // Budget only fits 2 of 3 requested turns
    }

    #[test]
    fn token_cap_single_large_turn() {
        // 1 turn that exceeds budget — must still preserve it (guarantee at least 1)
        let msgs = vec![Message::user("big q"), Message::assistant("huge response")];
        let deps = MockDeps::new(msgs.clone())
            .with_tokens(80_000, 1000)
            .with_token_fn(|_| 5000);
        // budget = 0.20 * 1000 = 200. Turn = 10000 tokens. But turns_seen==0 → include anyway.
        let engine = CompactionEngine::new(0.70, 1, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // Guarantee: at least 1 turn preserved
    }

    #[test]
    fn token_cap_exact_fit() {
        let msgs = vec![
            Message::user("a"),
            Message::assistant("b"),
            Message::user("c"),
            Message::assistant("d"),
        ];
        let deps = MockDeps::new(msgs.clone())
            .with_tokens(80_000, 2000)
            .with_token_fn(|_| 100);
        // budget = 0.20 * 2000 = 400. Each turn = 200. 2 turns = 400 ≤ 400 → fits exactly.
        let engine = CompactionEngine::new(0.70, 2, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // Both turns fit exactly
    }

    #[test]
    fn token_cap_zero_ratio() {
        let msgs = vec![
            Message::user("a"),
            Message::assistant("b"),
            Message::user("c"),
            Message::assistant("d"),
        ];
        let deps = MockDeps::new(msgs.clone());
        // max_preserved_ratio=0.0 → budget=0. First turn exceeds budget but turns_seen=0 → include.
        // Wait, budget=0. Turn cost > 0. turns_seen==0 → we include it.
        // Actually re-reading the algorithm: if budget is 0 and turn cost > 0 and turns_seen==0,
        // we still include it (guarantee at least 1 turn).
        // But preserve_recent_turns=2, so after turn 1, turns_seen=1 >= 0, next turn would
        // check budget: cost > 0 > budget=0 and turns_seen=1 > 0 → stop.
        let engine = CompactionEngine::new(0.70, 2, 0.0, deps);
        let split = engine.compute_split_point(&msgs);
        // First turn (last in list): U"c",A"d" — cost=200, budget=0, turns_seen=0 → include
        // Second turn: U"a",A"b" — cost=200, total=400 > 0, turns_seen=1 > 0 → stop
        assert_eq!(split, 2); // Only 1 turn preserved despite requesting 2
    }

    #[test]
    fn token_cap_partial_turn_excluded() {
        // 3 turns, middle one is huge, budget fits last turn but not middle + last
        let msgs = vec![
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            Message::assistant("huge response"),
            Message::user("q3"),
            Message::assistant("r3"),
        ];
        let deps = MockDeps::new(msgs.clone())
            .with_tokens(80_000, 10_000)
            .with_token_fn(|msg| {
                // Make the "huge response" assistant message very expensive
                if let Message::Assistant { content, .. } = msg {
                    if let Some(text) = content.first().and_then(|c| c.as_text()) {
                        if text == "huge response" {
                            return 5000;
                        }
                    }
                }
                100
            });
        // budget = 0.20 * 10_000 = 2000
        // Turn 3 (last): [q3, r3] = 200 ≤ 2000 → fits. turns_seen=1.
        // Turn 2: [q2, huge] = 5100. 200+5100=5300 > 2000, turns_seen=1>0 → stop.
        let engine = CompactionEngine::new(0.70, 3, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 4); // Only last turn preserved
    }

    // ========================================================================
    // compute_split_point — Category 4: Re-compaction
    // ========================================================================

    #[test]
    fn recompact_skips_summary() {
        // [Summary_U, Ack_A, U, A, U, A, U, A] — summary + 3 real turns, preserve 2
        let msgs = vec![
            compaction_summary("Previous context"),
            Message::assistant("I understand the previous context."),
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            Message::assistant("r2"),
            Message::user("q3"),
            Message::assistant("r3"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 4); // Summary not counted, preserve last 2 real turns
    }

    #[test]
    fn recompact_all_turns_fit() {
        // [Summary_U, Ack_A, U, A, U, A] — summary + 2 real turns, preserve 5
        let msgs = vec![
            compaction_summary("Previous context"),
            Message::assistant("Ack"),
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            Message::assistant("r2"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 5, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // Preserves everything including summary
    }

    #[test]
    fn recompact_summary_only() {
        // [Summary_U, Ack_A] — no real turns, nothing to compact further
        let msgs = vec![
            compaction_summary("Previous context"),
            Message::assistant("Ack"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        // No real user turns, preserve everything (nothing meaningful to summarize)
        assert_eq!(split, 0);
    }

    #[test]
    fn recompact_multiple_summaries() {
        // [S1, Ack1, S2, Ack2, U, A, U, A] — 2 real turns
        let msgs = vec![
            compaction_summary("First summary"),
            Message::assistant("Ack 1"),
            compaction_summary("Second summary"),
            Message::assistant("Ack 2"),
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            Message::assistant("r2"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 6); // Preserve last real turn only
    }

    // ========================================================================
    // compute_split_point — Category 5: Orphaned ToolResult prevention
    // ========================================================================

    #[test]
    fn orphan_split_on_user_is_clean() {
        // Turn-based split always lands on User, no fixup needed
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::user("q2"),
            Message::assistant("done"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 3); // Lands on U[3], clean
        assert!(msgs[split].is_user());
    }

    #[test]
    fn degenerate_leading_tool_result() {
        // [TR, U, A] — ToolResult before any User (shouldn't happen but must not panic)
        let msgs = vec![
            tool_result("tc_orphan"),
            Message::user("q"),
            Message::assistant("a"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 1); // Preserve from User onward
    }

    #[test]
    fn degenerate_all_tool_results() {
        // [A(tc), TR, TR] — no user turns, preserve everything
        let msgs = vec![
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            tool_result("tc2"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // No user turns found, preserve everything
    }

    // ========================================================================
    // compute_split_point — Category 6: Edge cases
    // ========================================================================

    #[test]
    fn empty_messages() {
        let msgs: Vec<Message> = vec![];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0);
    }

    #[test]
    fn single_user_no_response() {
        let msgs = vec![Message::user("hello")];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // Incomplete turn still preserved
    }

    #[test]
    fn assistant_first() {
        // [A, U, A] — leading assistant is summarized
        let msgs = vec![
            Message::assistant("preamble"),
            Message::user("q"),
            Message::assistant("a"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 1); // Leading assistant summarized
    }

    #[test]
    fn only_assistant_messages() {
        let msgs = vec![
            Message::assistant("a1"),
            Message::assistant("a2"),
            Message::assistant("a3"),
        ];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // No user turns found, preserve everything
    }

    #[test]
    fn preserve_turns_exceeds_total() {
        let msgs = vec![Message::user("hi"), Message::assistant("hello")];
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 100, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 0); // Preserve all
    }

    #[test]
    fn huge_message_count() {
        // 1000 messages (500 turns), preserve 5
        let msgs: Vec<Message> = (0..1000)
            .map(|i| {
                if i % 2 == 0 {
                    Message::user(format!("Q{}", i / 2))
                } else {
                    Message::assistant(format!("A{}", i / 2))
                }
            })
            .collect();
        let deps = MockDeps::new(msgs.clone());
        let engine = CompactionEngine::new(0.70, 5, 1.0, deps);
        let split = engine.compute_split_point(&msgs);
        assert_eq!(split, 990); // Last 10 messages = 5 turns
    }

    // ========================================================================
    // preview
    // ========================================================================

    #[tokio::test]
    async fn preview_generates_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Test summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.summary, "Test summary");
        assert_eq!(preview.tokens_before, 78_500);
    }

    #[tokio::test]
    async fn preview_turn_based() {
        let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();

        assert_eq!(preview.preserved_messages, 4); // 2 turns = 4 messages
        assert_eq!(preview.summarized_messages, 2);
        assert_eq!(preview.preserved_turns, 2);
        assert_eq!(preview.summarized_turns, 1);
    }

    #[tokio::test]
    async fn preview_with_extracted_data() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Summary");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert!(preview.extracted_data.is_some());
    }

    #[tokio::test]
    async fn preview_empty_messages() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("");

        let preview = engine.preview(&summarizer).await.unwrap();
        assert_eq!(preview.preserved_messages, 0);
        assert_eq!(preview.summarized_messages, 0);
    }

    // ========================================================================
    // execute
    // ========================================================================

    #[tokio::test]
    async fn execute_compaction_updates_messages() {
        let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Compacted summary");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.success);
        assert_eq!(result.summary, "Compacted summary");
        // 3 turns, preserve 2 → summarize first turn (2 msgs)
        // New: summary + ack + 4 preserved = 6
        let new_msgs = engine.deps.get_messages();
        assert_eq!(new_msgs.len(), 6);
    }

    #[tokio::test]
    async fn execute_uses_edited_summary() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Original");

        let result = engine
            .execute(&summarizer, Some("User edited"))
            .await
            .unwrap();

        assert_eq!(result.summary, "User edited");
        assert!(result.extracted_data.is_none());
    }

    #[tokio::test]
    async fn execute_returns_turn_counts() {
        let deps = MockDeps::new(default_messages()); // 3 turns
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Summary");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert_eq!(result.preserved_turns, 2);
        assert_eq!(result.summarized_turns, 1);
    }

    #[tokio::test]
    async fn execute_token_cap_reflected() {
        // 5 turns, budget fits 3, preserve=5
        let msgs: Vec<Message> = (0..10)
            .map(|i| {
                if i % 2 == 0 {
                    Message::user(format!("Q{}", i / 2))
                } else {
                    Message::assistant(format!("A{}", i / 2))
                }
            })
            .collect();
        let deps = MockDeps::new(msgs)
            .with_tokens(80_000, 3000)
            .with_token_fn(|_| 100);
        // budget = 0.20 * 3000 = 600. Each turn = 200 tokens.
        // Turn 5 (last): 200 ≤ 600 → fits. Turn 4: 400 ≤ 600 → fits. Turn 3: 600 ≤ 600 → fits.
        // Turn 2: 800 > 600, turns_seen=3>0 → stop.
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        let summarizer = MockSummarizer::new("Summary");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert_eq!(result.preserved_turns, 3); // Budget limited to 3
    }

    #[tokio::test]
    async fn execute_recompact_correct() {
        // Pre-compacted messages + 3 new turns, preserve 2
        let msgs = vec![
            compaction_summary("Previous context"),
            Message::assistant("Ack"),
            Message::user("q1"),
            Message::assistant("r1"),
            Message::user("q2"),
            Message::assistant("r2"),
            Message::user("q3"),
            Message::assistant("r3"),
        ];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Re-compacted summary");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert!(result.success);
        assert_eq!(result.preserved_turns, 2);
        assert_eq!(result.summarized_turns, 1); // Only real turns in summarized portion
    }

    #[tokio::test]
    async fn execute_summary_format() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
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

    #[tokio::test]
    async fn execute_preserve_zero() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 0, 0.20, deps);
        let summarizer = MockSummarizer::new("Everything summarized");

        let result = engine.execute(&summarizer, None).await.unwrap();
        let new_msgs = engine.deps.get_messages();

        assert!(result.success);
        assert_eq!(result.preserved_turns, 0);
        assert_eq!(result.summarized_turns, 3);
        assert_eq!(new_msgs.len(), 2); // Only summary + ack
    }

    #[tokio::test]
    async fn execute_skips_when_all_within_preserve_window() {
        let msgs = vec![Message::user("Hi"), Message::assistant("Hello")];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 5, 1.0, deps);
        let summarizer = MockSummarizer::new("Should not be called");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.success);
        assert!(result.summary.is_empty());
        assert_eq!(result.tokens_before, result.tokens_after);
    }

    #[tokio::test]
    async fn execute_returns_compression_ratio() {
        let deps = MockDeps::new(default_messages());
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let summarizer = MockSummarizer::new("Short");

        let result = engine.execute(&summarizer, None).await.unwrap();

        assert!(result.compression_ratio > 0.0);
        assert!(result.compression_ratio <= 1.0);
    }

    // ========================================================================
    // onNeeded
    // ========================================================================

    #[test]
    fn trigger_if_needed_fires_callback() {
        let deps = MockDeps::new(default_messages());
        let mut engine = CompactionEngine::new(0.70, 5, 0.20, deps);

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
        let mut engine = CompactionEngine::new(0.70, 5, 0.20, deps);

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
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        engine.trigger_if_needed();
    }

    // ========================================================================
    // message_only_tokens
    // ========================================================================

    #[test]
    fn message_only_tokens_subtracts_overhead() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert_eq!(engine.message_only_tokens(), 78_500);
    }

    #[test]
    fn message_only_tokens_saturates_at_zero() {
        let deps = MockDeps::new(vec![]).with_tokens(500, 100_000);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        assert_eq!(engine.message_only_tokens(), 0);
    }

    // ========================================================================
    // estimate_tokens_after_compaction
    // ========================================================================

    #[test]
    fn estimate_after_compaction_components() {
        let deps = MockDeps::new(vec![]);
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        let preserved = [Message::user("msg1"), Message::user("msg2")];

        let result = engine.estimate_tokens_after_compaction("Short summary", &preserved);

        // summary: ceil(13/4) = 4, context: 50, ack: 50, preserved: 2 * 100 = 200
        assert_eq!(result, 304);
    }

    #[test]
    fn token_estimation_uses_deps() {
        let deps = MockDeps {
            messages: Mutex::new(RefCell::new(vec![])),
            current_tokens: 80_000,
            context_limit: 100_000,
            system_prompt_tokens: 1_000,
            tools_tokens: 500,
            message_token_value: 250,
            token_fn: None,
        };
        let engine = CompactionEngine::new(0.70, 5, 0.20, deps);
        let preserved = [Message::user("test")];
        let result = engine.estimate_tokens_after_compaction("s", &preserved);
        // summary: 1, context: 50, ack: 50, preserved: 250
        assert_eq!(result, 351);
    }

    // ========================================================================
    // Integration: no orphaned tool results
    // ========================================================================

    /// Assert that every `ToolResult` in `messages` has a preceding `Assistant`
    /// containing a `ToolUse` with the matching ID.
    fn assert_no_orphaned_tool_results(messages: &[Message]) {
        for (i, msg) in messages.iter().enumerate() {
            if let Message::ToolResult { tool_call_id, .. } = msg {
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
        // 3 turns, preserve 1
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 1, 1.0, deps);
        let summarizer = MockSummarizer::new("Summary of tool usage");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert!(result.success);

        assert_no_orphaned_tool_results(&engine.deps.get_messages());
    }

    #[tokio::test]
    async fn execute_turn_based_no_orphans() {
        // Tool-heavy conversation, preserve 2 turns
        let msgs = vec![
            Message::user("q1"),
            assistant_with_tool_use(&["tc1"]),
            tool_result("tc1"),
            Message::assistant("r1"),
            Message::user("q2"),
            assistant_with_tool_use(&["tc2", "tc3"]),
            tool_result("tc2"),
            tool_result("tc3"),
            Message::assistant("r2"),
            Message::user("q3"),
            Message::assistant("r3"),
        ];
        let deps = MockDeps::new(msgs);
        let engine = CompactionEngine::new(0.70, 2, 1.0, deps);
        let summarizer = MockSummarizer::new("Summary");

        let result = engine.execute(&summarizer, None).await.unwrap();
        assert!(result.success);
        assert_no_orphaned_tool_results(&engine.deps.get_messages());
    }
}
