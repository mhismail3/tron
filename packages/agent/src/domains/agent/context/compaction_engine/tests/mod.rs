use super::*;
mod estimation_orphans;
mod preview_execute;
mod split_point;
use crate::domains::agent::context::types::SummaryResult;
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
        content: crate::shared::protocol::messages::CapabilityResultMessageContent::Text(
            "ok".into(),
        ),
        is_error: None,
    }
}

/// Helper: create a compaction summary message.
fn compaction_summary(text: &str) -> Message {
    Message::user(format!("{COMPACTION_SUMMARY_PREFIX}\n\n{text}"))
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
