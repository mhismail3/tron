//! Summarizer trait and utilities for compaction.
//!
//! Defines the [`Summarizer`] trait used by the compaction engine, plus the
//! deterministic [`KeywordSummarizer`] retained by the primitive loop.

use serde_json::Value;

use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};

use super::types::{ExtractedData, SummaryResult};

// =============================================================================
// Summarizer Trait
// =============================================================================

/// Trait for generating compaction summaries from conversation messages.
///
/// The primitive loop retains [`KeywordSummarizer`] as a deterministic bounded
/// summarizer using chronological and semantic-salience extraction.
#[async_trait::async_trait]
pub trait Summarizer: Send + Sync {
    /// Summarize a sequence of messages into a structured result.
    async fn summarize(
        &self,
        messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>>;
}

// =============================================================================
// Keyword Summarizer
// =============================================================================

/// Deterministic bounded summarizer for the primitive loop.
///
/// It preserves chronological edges plus explicit constraints, decisions, and
/// importance markers from the middle of long sessions, then extracts file
/// paths and capability ids. Raw history remains the durable source of truth.
pub struct KeywordSummarizer;

impl KeywordSummarizer {
    /// Create a new keyword summarizer.
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

impl Default for KeywordSummarizer {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait::async_trait]
impl Summarizer for KeywordSummarizer {
    async fn summarize(
        &self,
        messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        let mut user_messages = Vec::new();
        let mut files_modified = Vec::new();
        let mut topics = Vec::new();
        let mut model_capability_names = Vec::new();
        let mut assistant_outcomes = Vec::new();
        let mut capability_outcomes = Vec::new();

        for msg in messages {
            match msg {
                Message::User { content, .. } => {
                    let text = user_content_text(content);
                    if !text.is_empty() {
                        user_messages.push(truncate(&text, 240));
                    }
                }
                Message::Assistant { content, .. } => {
                    for block in content {
                        match block {
                            AssistantContent::CapabilityInvocation {
                                name, arguments, ..
                            } => {
                                if !model_capability_names.contains(name) {
                                    model_capability_names.push(name.clone());
                                }
                                if let Some(path) = arguments
                                    .get("file_path")
                                    .or_else(|| arguments.get("path"))
                                    .and_then(Value::as_str)
                                {
                                    let p = path.to_string();
                                    if !files_modified.contains(&p) {
                                        files_modified.push(p);
                                    }
                                }
                            }
                            AssistantContent::Text { text } => {
                                let outcome = truncate(text.trim(), 240);
                                if !outcome.is_empty() {
                                    assistant_outcomes.push(outcome);
                                }
                                if let Some(first_sentence) = text.split('.').next() {
                                    let topic = truncate(first_sentence.trim(), 80);
                                    if !topic.is_empty() && !topics.contains(&topic) {
                                        topics.push(topic);
                                    }
                                }
                            }
                            AssistantContent::Thinking { .. } => {}
                        }
                    }
                }
                Message::CapabilityResult {
                    content, is_error, ..
                } => {
                    let text = capability_result_text(content);
                    if !text.is_empty() {
                        let status = if *is_error == Some(true) {
                            "Capability error"
                        } else {
                            "Capability result"
                        };
                        capability_outcomes.push(format!("{status}: {}", truncate(&text, 200)));
                    }
                }
            }
        }

        let narrative = if user_messages.is_empty() {
            format!("({} messages summarized)", messages.len())
        } else {
            let mut parts = Vec::new();
            parts.push(format!("The user made {} requests.", user_messages.len()));
            parts.push(format!(
                "Key requests: {}",
                bounded_salient_sequence(&user_messages, 6).join("; ")
            ));
            if !assistant_outcomes.is_empty() {
                parts.push(format!(
                    "Assistant outcomes and decisions: {}",
                    bounded_salient_sequence(&assistant_outcomes, 6).join("; ")
                ));
            }
            if !capability_outcomes.is_empty() {
                parts.push(format!(
                    "Execution outcomes: {}",
                    bounded_salient_sequence(&capability_outcomes, 4).join("; ")
                ));
            }
            if !model_capability_names.is_empty() {
                parts.push(format!(
                    "Capabilities used: {}",
                    model_capability_names.join(", ")
                ));
            }
            if !files_modified.is_empty() {
                parts.push(format!("Files touched: {}", files_modified.join(", ")));
            }
            parts.join(" ")
        };

        Ok(SummaryResult {
            narrative,
            extracted_data: ExtractedData {
                current_goal: user_messages.last().cloned().unwrap_or_default(),
                completed_steps: bounded_salient_sequence(&assistant_outcomes, 6),
                pending_tasks: Vec::new(),
                key_decisions: bounded_salient_sequence(&assistant_outcomes, 6)
                    .into_iter()
                    .map(|decision| super::types::KeyDecision {
                        decision,
                        reason: "Recovered from prior assistant output".to_owned(),
                    })
                    .collect(),
                files_modified,
                topics_discussed: topics,
                user_preferences: Vec::new(),
                important_context: Vec::new(),
                thinking_insights: Vec::new(),
            },
        })
    }
}

/// Truncate a string to a maximum length, appending "..." if truncated.
fn truncate(s: &str, max_len: usize) -> String {
    crate::shared::foundation::text::truncate_with_suffix(s, max_len, "...")
}

// =============================================================================
// Content text extraction helpers
// =============================================================================

/// Extract text from a `UserMessageContent`.
fn user_content_text(content: &UserMessageContent) -> String {
    match content {
        UserMessageContent::Text(t) => t.clone(),
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| b.as_text())
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn capability_result_text(content: &CapabilityResultMessageContent) -> String {
    match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn bounded_salient_sequence(values: &[String], limit: usize) -> Vec<String> {
    if limit == 0 {
        return Vec::new();
    }
    if values.len() <= limit {
        return values.to_vec();
    }

    let mut selected = std::collections::BTreeSet::new();
    let _ = selected.insert(0);
    let _ = selected.insert(values.len() - 1);
    if limit >= 4 {
        let _ = selected.insert(1);
        let _ = selected.insert(values.len() - 2);
    }

    let mut salient = values
        .iter()
        .enumerate()
        .filter(|(index, _)| !selected.contains(index))
        .map(|(index, value)| (semantic_salience(value), index))
        .filter(|(score, _)| *score > 0)
        .collect::<Vec<_>>();
    salient.sort_by(|(left_score, left_index), (right_score, right_index)| {
        right_score
            .cmp(left_score)
            .then_with(|| left_index.cmp(right_index))
    });
    for (_, index) in salient {
        if selected.len() == limit {
            break;
        }
        let _ = selected.insert(index);
    }

    // Fill remaining capacity across the whole chronology instead of allowing
    // a long middle region to disappear deterministically.
    for step in 1..values.len() {
        if selected.len() == limit {
            break;
        }
        let index = step * (values.len() - 1) / values.len();
        let _ = selected.insert(index);
    }

    selected
        .into_iter()
        .take(limit)
        .map(|index| values[index].clone())
        .collect()
}

fn semantic_salience(value: &str) -> usize {
    const MARKERS: &[&str] = &[
        "critical",
        "important",
        "must",
        "never",
        "always",
        "constraint",
        "decision",
        "preserve",
        "required",
        "do not",
        "don't",
        "cannot",
        "should not",
        "invariant",
        "preference",
        "remember",
    ];
    let lower = value.to_ascii_lowercase();
    MARKERS
        .iter()
        .filter(|marker| lower.contains(**marker))
        .count()
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::UserContent;
    use serde_json::json;

    #[test]
    fn truncate_bounds_long_string() {
        let result = truncate("hello world", 8);
        assert!(result.ends_with("..."));
        assert!(result.len() <= 8);
    }

    #[tokio::test]
    async fn keyword_summarizer_basic() {
        let summarizer = KeywordSummarizer;
        let messages = vec![
            Message::user("Fix the login bug"),
            Message::assistant("I'll look at the login code."),
        ];
        let result = summarizer.summarize(&messages).await.unwrap();
        assert!(!result.narrative.is_empty());
        assert!(result.narrative.contains("1 requests"));
    }

    #[tokio::test]
    async fn keyword_summarizer_extracts_files() {
        let summarizer = KeywordSummarizer;
        let mut args = serde_json::Map::new();
        let _ = args.insert("file_path".into(), json!("/src/login.rs"));
        let messages = vec![
            Message::user("Fix the login"),
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "tc-1".into(),
                    name: "inspect".into(),
                    arguments: args,
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];
        let result = summarizer.summarize(&messages).await.unwrap();
        assert!(
            result
                .extracted_data
                .files_modified
                .contains(&"/src/login.rs".to_string())
        );
    }

    #[tokio::test]
    async fn keyword_summarizer_empty_messages() {
        let summarizer = KeywordSummarizer;
        let result = summarizer.summarize(&[]).await.unwrap();
        assert!(result.narrative.contains("0 messages summarized"));
    }

    #[tokio::test]
    async fn keyword_summarizer_preserves_late_decisions_and_execution_outcomes() {
        let mut messages = (0..20)
            .map(|index| Message::user(format!("request-{index} {}", "x".repeat(500))))
            .collect::<Vec<_>>();
        messages.push(Message::assistant(
            "LATE-DECISION: keep the transactional boundary.",
        ));
        messages.push(Message::CapabilityResult {
            invocation_id: "cap-late".into(),
            content: CapabilityResultMessageContent::Text("LATE-RESULT: validation passed".into()),
            is_error: Some(false),
        });

        let result = KeywordSummarizer.summarize(&messages).await.unwrap();
        assert!(result.narrative.len() <= 4_000);
        assert!(result.narrative.contains("request-19"));
        assert!(result.narrative.contains("LATE-DECISION"));
        assert!(result.narrative.contains("LATE-RESULT"));
    }

    #[tokio::test]
    async fn keyword_summarizer_preserves_critical_middle_request_and_decision() {
        let mut messages = Vec::new();
        for index in 0..10 {
            let request = if index == 1 {
                "request-1 CRITICAL-MIDDLE-REQUEST: preserve the CERULEAN invariant".to_owned()
            } else {
                format!("request-{index} routine detail")
            };
            messages.push(Message::user(request));
            let outcome = if index == 4 {
                "IMPORTANT-MIDDLE-DECISION: never weaken the transactional boundary".to_owned()
            } else {
                format!("outcome-{index} completed")
            };
            messages.push(Message::assistant(outcome));
        }

        let result = KeywordSummarizer.summarize(&messages).await.unwrap();
        assert!(result.narrative.contains("CRITICAL-MIDDLE-REQUEST"));
        assert!(result.narrative.contains("IMPORTANT-MIDDLE-DECISION"));
        assert!(result.narrative.contains("request-9"));
    }

    // -- User content helpers --

    #[test]
    fn user_content_text_joins_blocks() {
        let content = UserMessageContent::Blocks(vec![
            UserContent::Text {
                text: "First block".into(),
            },
            UserContent::Text {
                text: "Second block".into(),
            },
        ]);
        let result = user_content_text(&content);
        assert_eq!(result, "First block\nSecond block");
    }

    // -- user_content_text --

    #[test]
    fn user_content_text_from_string() {
        let content = UserMessageContent::Text("hello".into());
        assert_eq!(user_content_text(&content), "hello");
    }

    #[test]
    fn user_content_text_from_blocks() {
        let content =
            UserMessageContent::Blocks(vec![UserContent::text("one"), UserContent::text("two")]);
        assert_eq!(user_content_text(&content), "one\ntwo");
    }
}
