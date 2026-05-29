use super::*;
use crate::domains::agent::runner::context::types::SummaryResult;
use std::cell::RefCell;
use std::sync::Mutex;

// -- Mock deps --

struct MockDeps {
    messages: Mutex<RefCell<Vec<Message>>>,
    current_tokens: u64,
    context_limit: u64,
    system_prompt_tokens: u64,
    capabilities_tokens: u64,
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
            capabilities_tokens: 500,
            message_token_value: 100,
            token_fn: None,
        }
    }

    fn with_tokens(mut self, current: u64, limit: u64) -> Self {
        self.current_tokens = current;
        self.context_limit = limit;
        self
    }

    fn with_token_fn(mut self, f: impl Fn(&Message) -> u64 + Send + Sync + 'static) -> Self {
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

    fn estimate_capabilities_tokens(&self) -> u64 {
        self.capabilities_tokens
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

struct PanicSummarizer;

#[async_trait::async_trait]
impl Summarizer for PanicSummarizer {
    async fn summarize(
        &self,
        _messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        panic!("summarizer must not be called when no messages are summarizable");
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

/// Helper: create an assistant message with `capability_invocation` blocks.
fn assistant_with_capability_invocation(ids: &[&str]) -> Message {
    Message::Assistant {
        content: ids
            .iter()
            .map(|id| AssistantContent::CapabilityInvocation {
                id: (*id).into(),
                name: "test_capability".into(),
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

/// Helper: create a capability result message.
fn capability_result(id: &str) -> Message {
    Message::CapabilityResult {
        invocation_id: id.into(),
        content: crate::shared::messages::CapabilityResultMessageContent::Text("ok".into()),
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
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert!(engine.should_compact());
}

#[test]
fn should_compact_below_threshold() {
    let deps = MockDeps::new(default_messages()).with_tokens(60_000, 100_000);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert!(!engine.should_compact());
}

#[test]
fn should_compact_at_exact_threshold() {
    let deps = MockDeps::new(default_messages()).with_tokens(70_000, 100_000);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert!(engine.should_compact());
}

#[test]
fn should_compact_zero_limit() {
    let deps = MockDeps::new(default_messages()).with_tokens(80_000, 0);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert!(!engine.should_compact());
}

#[test]
fn has_summarizable_messages_false_for_single_preserved_turn() {
    let deps = MockDeps::new(vec![Message::user("Hi"), Message::assistant("Hello")]);
    let engine = CompactionEngine::new(0.70, 3, deps);

    assert!(!engine.has_summarizable_messages());
}

#[test]
fn has_summarizable_messages_true_when_older_turn_exists() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 2, deps);

    assert!(engine.has_summarizable_messages());
}

// ========================================================================
// compute_split_point — Category 1: Basic turn counting
// ========================================================================

#[test]
fn basic_3_turns_preserve_2() {
    // [U,A,U,A,U,A] — 3 turns, preserve 2
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 2, deps);
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
    let engine = CompactionEngine::new(0.70, 3, deps);
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
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // preserve everything
}

#[test]
fn basic_single_turn() {
    let msgs = vec![Message::user("hi"), Message::assistant("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve it all
}

#[test]
fn basic_preserve_zero() {
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 0, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 6); // summarize all
}

// ========================================================================
// compute_split_point — Category 2: ModelCapability-heavy turns
// ========================================================================

#[test]
fn capability_heavy_single_turn() {
    // [U, A(tc), TR, A(tc), TR, A(text)] — 1 turn = 6 messages
    let msgs = vec![
        Message::user("do stuff"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        assistant_with_capability_invocation(&["tc2"]),
        capability_result("tc2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve all
}

#[test]
fn capability_heavy_preserve_1_of_2() {
    // [U,A, U,A(tc),TR,TR,A] — 2 turns, preserve 1
    let msgs = vec![
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Last turn starts at U[2]
}

#[test]
fn parallel_capabilities_one_turn() {
    // [U, A(tc1,tc2), TR1, TR2, A] — 1 turn
    let msgs = vec![
        Message::user("do both"),
        assistant_with_capability_invocation(&["tc1", "tc2"]),
        capability_result("tc1"),
        capability_result("tc2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // 1 turn, preserve all
}

#[test]
fn mixed_capability_and_simple() {
    // [U,A, U,A(tc),TR,A, U,A] — 3 turns, preserve 2
    let msgs = vec![
        Message::user("q1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::assistant("done capability"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 2, deps);
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
        .with_tokens(80_000, 3000)
        .with_token_fn(|_| 500);
    // budget = threshold * context_limit = 0.70 * 3000 = 2100. Each turn = 1000 tokens.
    // Turn 3 (last): 1000 ≤ 2100 → fits. Turn 2: 1000+1000=2000 ≤ 2100 → fits.
    // Turn 1: 1000+2000=3000 > 2100 and turns_seen=2 > 0 → stop.
    let engine = CompactionEngine::new(0.70, 3, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 2); // Budget only fits 2 of 3 requested turns
}

#[test]
fn token_cap_single_large_turn() {
    // 1 turn that exceeds budget — must still preserve it (guarantee at least 1)
    let msgs = vec![Message::user("big q"), Message::assistant("huge response")];
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(80_000, 100)
        .with_token_fn(|_| 5000);
    // budget = 0.70 * 100 = 70. Turn = 10000 tokens. But turns_seen==0 → include anyway.
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    // budget = 0.70 * 2000 = 1400. Each turn = 200. 2 turns = 400 ≤ 1400 → fits.
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // Both turns fit
}

#[test]
fn token_cap_tiny_budget() {
    // Very small context_limit makes budget ≈ 0, but we still guarantee at least 1 turn.
    let msgs = vec![
        Message::user("a"),
        Message::assistant("b"),
        Message::user("c"),
        Message::assistant("d"),
    ];
    let deps = MockDeps::new(msgs.clone()).with_tokens(80_000, 1);
    // budget = 0.70 * 1 = 0 (truncated). Turn cost > 0, turns_seen==0 → include anyway.
    // After first turn, turns_seen=1 > 0, next turn exceeds budget → stop.
    let engine = CompactionEngine::new(0.70, 2, deps);
    let split = engine.compute_split_point(&msgs);
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
        .with_tokens(80_000, 3000)
        .with_token_fn(|msg| {
            // Make the "huge response" assistant message very expensive
            if let Message::Assistant { content, .. } = msg
                && let Some(text) = content.first().and_then(|c| c.as_text())
                && text == "huge response"
            {
                return 5000;
            }
            100
        });
    // budget = 0.70 * 3000 = 2100
    // Turn 3 (last): [q3, r3] = 200 ≤ 2100 → fits. turns_seen=1.
    // Turn 2: [q2, huge] = 5100. 200+5100=5300 > 2100, turns_seen=1>0 → stop.
    let engine = CompactionEngine::new(0.70, 3, deps);
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
    let engine = CompactionEngine::new(0.70, 2, deps);
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
    let engine = CompactionEngine::new(0.70, 5, deps);
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
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 6); // Preserve last real turn only
}

// ========================================================================
// compute_split_point — Category 5: Orphaned CapabilityResult prevention
// ========================================================================

#[test]
fn orphan_split_on_user_is_clean() {
    // Turn-based split always lands on User, no fixup needed
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::user("q2"),
        Message::assistant("done"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 3); // Lands on U[3], clean
    assert!(msgs[split].is_user());
}

#[test]
fn degenerate_leading_capability_result() {
    // [TR, U, A] — CapabilityResult before any User (shouldn't happen but must not panic)
    let msgs = vec![
        capability_result("tc_orphan"),
        Message::user("q"),
        Message::assistant("a"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 1); // Preserve from User onward
}

#[test]
fn degenerate_all_capability_results() {
    // [A(tc), TR, TR] — no user turns, preserve everything
    let msgs = vec![
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        capability_result("tc2"),
    ];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0);
}

#[test]
fn single_user_no_response() {
    let msgs = vec![Message::user("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    let engine = CompactionEngine::new(0.70, 1, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 0); // No user turns found, preserve everything
}

#[test]
fn preserve_turns_exceeds_total() {
    let msgs = vec![Message::user("hi"), Message::assistant("hello")];
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 100, deps);
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
    let engine = CompactionEngine::new(0.70, 5, deps);
    let split = engine.compute_split_point(&msgs);
    assert_eq!(split, 990); // Last 10 messages = 5 turns
}

// ========================================================================
// preview
// ========================================================================

#[tokio::test]
async fn preview_generates_summary() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Test summary");

    let preview = engine.preview(&summarizer).await.unwrap();

    assert_eq!(preview.summary, "Test summary");
    assert_eq!(preview.tokens_before, 78_500);
}

#[tokio::test]
async fn preview_turn_based() {
    let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
    let engine = CompactionEngine::new(0.70, 2, deps);
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
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let preview = engine.preview(&summarizer).await.unwrap();
    assert!(preview.extracted_data.is_some());
}

#[tokio::test]
async fn preview_empty_messages() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = PanicSummarizer;

    let preview = engine.preview(&summarizer).await.unwrap();
    assert_eq!(preview.preserved_messages, 0);
    assert_eq!(preview.summarized_messages, 0);
    assert_eq!(preview.summary, "");
}

// ========================================================================
// execute
// ========================================================================

#[tokio::test]
async fn execute_compaction_updates_messages() {
    let deps = MockDeps::new(default_messages()); // 6 messages, 3 turns
    let engine = CompactionEngine::new(0.70, 2, deps);
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
    let engine = CompactionEngine::new(0.70, 2, deps);
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
    let engine = CompactionEngine::new(0.70, 2, deps);
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
        .with_tokens(80_000, 860)
        .with_token_fn(|_| 100);
    // budget = 0.70 * 860 = 602. Each turn = 200 tokens.
    // Turn 5 (last): 200 ≤ 602 → fits. Turn 4: 400 ≤ 602 → fits. Turn 3: 600 ≤ 602 → fits.
    // Turn 2: 800 > 602, turns_seen=3>0 → stop.
    let engine = CompactionEngine::new(0.70, 5, deps);
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
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Re-compacted summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);
    assert_eq!(result.preserved_turns, 2);
    assert_eq!(result.summarized_turns, 1); // Only real turns in summarized portion
}

#[tokio::test]
async fn execute_summary_format() {
    let deps = MockDeps::new(default_messages());
    let engine = CompactionEngine::new(0.70, 1, deps);
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
    let engine = CompactionEngine::new(0.70, 0, deps);
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
    let deps = MockDeps::new(msgs.clone());
    let engine = CompactionEngine::new(0.70, 5, deps);
    let summarizer = PanicSummarizer;

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(!result.success);
    assert!(result.summary.is_empty());
    assert_eq!(result.tokens_before, result.tokens_after);
    assert_eq!(engine.deps.get_messages(), msgs);
}

#[tokio::test]
async fn execute_skips_when_summary_would_not_reduce_context() {
    let msgs = default_messages();
    let deps = MockDeps::new(msgs.clone()).with_tokens(1_700, 100_000);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();

    assert!(!result.success);
    assert!(result.tokens_after >= result.tokens_before);
    assert!(result.summary.is_empty());
    assert_eq!(engine.deps.get_messages(), msgs);
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

// ========================================================================
// onNeeded
// ========================================================================

#[test]
fn trigger_if_needed_fires_callback() {
    let deps = MockDeps::new(default_messages());
    let mut engine = CompactionEngine::new(0.70, 5, deps);

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
    let mut engine = CompactionEngine::new(0.70, 5, deps);

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
    let engine = CompactionEngine::new(0.70, 5, deps);
    engine.trigger_if_needed();
}

// ========================================================================
// message_only_tokens
// ========================================================================

#[test]
fn message_only_tokens_subtracts_overhead() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert_eq!(engine.message_only_tokens(), 78_500);
}

#[test]
fn message_only_tokens_saturates_at_zero() {
    let deps = MockDeps::new(vec![]).with_tokens(500, 100_000);
    let engine = CompactionEngine::new(0.70, 5, deps);
    assert_eq!(engine.message_only_tokens(), 0);
}

// ========================================================================
// estimate_tokens_after_compaction
// ========================================================================

#[test]
fn estimate_after_compaction_components() {
    let deps = MockDeps::new(vec![]);
    let engine = CompactionEngine::new(0.70, 5, deps);
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
        capabilities_tokens: 500,
        message_token_value: 250,
        token_fn: None,
    };
    let engine = CompactionEngine::new(0.70, 5, deps);
    let preserved = [Message::user("test")];
    let result = engine.estimate_tokens_after_compaction("s", &preserved);
    // summary: 1, context: 50, ack: 50, preserved: 250
    assert_eq!(result, 351);
}

// ========================================================================
// Integration: no orphaned capability results
// ========================================================================

/// Assert that every `CapabilityResult` in `messages` has a preceding `Assistant`
/// containing a `CapabilityInvocation` with the matching ID.
fn assert_no_orphaned_capability_results(messages: &[Message]) {
    for (i, msg) in messages.iter().enumerate() {
        if let Message::CapabilityResult { invocation_id, .. } = msg {
            let has_matching_capability_invocation = (0..i).rev().any(|j| {
                if let Message::Assistant { content, .. } = &messages[j] {
                    content.iter().any(|c| {
                        if let AssistantContent::CapabilityInvocation { id, .. } = c {
                            id == invocation_id
                        } else {
                            false
                        }
                    })
                } else {
                    false
                }
            });
            assert!(
                has_matching_capability_invocation,
                "CapabilityResult(invocation_id={invocation_id}) at index {i} has no \
                 preceding Assistant with matching CapabilityInvocation"
            );
        }
    }
}

#[tokio::test]
async fn execute_compaction_no_orphaned_capability_results() {
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::user("q3"),
        Message::assistant("final"),
    ];
    // 3 turns, preserve 1
    let deps = MockDeps::new(msgs);
    let engine = CompactionEngine::new(0.70, 1, deps);
    let summarizer = MockSummarizer::new("Summary of capability usage");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);

    assert_no_orphaned_capability_results(&engine.deps.get_messages());
}

#[tokio::test]
async fn execute_turn_based_no_orphans() {
    // ModelCapability-heavy conversation, preserve 2 turns
    let msgs = vec![
        Message::user("q1"),
        assistant_with_capability_invocation(&["tc1"]),
        capability_result("tc1"),
        Message::assistant("r1"),
        Message::user("q2"),
        assistant_with_capability_invocation(&["tc2", "tc3"]),
        capability_result("tc2"),
        capability_result("tc3"),
        Message::assistant("r2"),
        Message::user("q3"),
        Message::assistant("r3"),
    ];
    let deps = MockDeps::new(msgs);
    let engine = CompactionEngine::new(0.70, 2, deps);
    let summarizer = MockSummarizer::new("Summary");

    let result = engine.execute(&summarizer, None).await.unwrap();
    assert!(result.success);
    assert_no_orphaned_capability_results(&engine.deps.get_messages());
}

// ========================================================================
// 65K context window — local-model ceiling (Ollama)
//
// Ollama sessions run with `num_ctx = 65_536` and the default compaction
// threshold of 0.70. These tests pin the split-point math and capability-result
// sizer at that window so the local path is parametrically covered.
// ========================================================================

const LOCAL_CTX_LIMIT: u64 = 65_536;
const DEFAULT_COMPACT_THRESHOLD: f64 = 0.70;

#[test]
fn local_window_no_compact_well_below_threshold() {
    // 45,000 / 65,536 ≈ 0.686 — below 0.70, no compaction.
    let deps = MockDeps::new(default_messages()).with_tokens(45_000, LOCAL_CTX_LIMIT);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 5, deps);
    assert!(!engine.should_compact());
}

#[test]
fn local_window_compacts_above_threshold() {
    // 50,000 / 65,536 ≈ 0.763 — above 0.70, compaction fires.
    let deps = MockDeps::new(default_messages()).with_tokens(50_000, LOCAL_CTX_LIMIT);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 5, deps);
    assert!(engine.should_compact());
}

#[test]
fn local_window_all_turns_fit_under_budget() {
    // Budget = threshold * context_limit = 0.70 * 65_536 ≈ 45_875 tokens.
    // 12 messages × 3_500 tokens = 6 turns × 7_000 tokens = 42_000 — all fit.
    // With preserve_recent=10 (> turn count), the turn cap never kicks in, so
    // the budget alone governs and all turns are preserved → split = 0.
    let msgs: Vec<Message> = (0..12)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(50_000, LOCAL_CTX_LIMIT)
        .with_token_fn(|_| 3_500);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 10, deps);
    assert_eq!(engine.compute_split_point(&msgs), 0);
}

#[test]
fn local_window_budget_caps_preserved_turns() {
    // Budget = 0.70 * 65_536 ≈ 45_875 tokens. 20 messages × 4_000 tokens
    // each = 10 turns × 8_000 tokens:
    //   - 5 turns × 8_000 = 40_000 ≤ 45_875 → fit
    //   - 6th turn pushes total to 48_000 > 45_875 AND turns_seen=5>0 → stop
    // With preserve_recent=10 (≥ turn count), budget is the binding constraint.
    // Expect split at message index 10 (first 10 compacted, last 10 preserved).
    let msgs: Vec<Message> = (0..20)
        .map(|i| {
            if i % 2 == 0 {
                Message::user(format!("Q{}", i / 2))
            } else {
                Message::assistant(format!("A{}", i / 2))
            }
        })
        .collect();
    let deps = MockDeps::new(msgs.clone())
        .with_tokens(60_000, LOCAL_CTX_LIMIT)
        .with_token_fn(|_| 4_000);
    let engine = CompactionEngine::new(DEFAULT_COMPACT_THRESHOLD, 10, deps);
    assert_eq!(
        engine.compute_split_point(&msgs),
        10,
        "budget should cap at 5 turns (10 messages)"
    );
}
