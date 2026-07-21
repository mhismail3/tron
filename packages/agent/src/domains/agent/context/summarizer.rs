//! Summarizer trait and utilities for compaction.
//!
//! Defines the [`Summarizer`] trait used by the compaction engine, plus the
//! deterministic [`KeywordSummarizer`] retained by the primitive loop.

use serde_json::Value;

use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::messages::{Message, UserMessageContent};

use super::types::SummaryResult;

// =============================================================================
// Summarizer Trait
// =============================================================================

/// Trait for generating compaction summaries from conversation messages.
///
/// The primitive loop retains [`KeywordSummarizer`] as a deterministic recovery
/// summarizer using keyword extraction.
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

/// Fast recovery summarizer that extracts keywords from messages.
///
/// Used when the LLM summarizer fails (timeout, parse error, etc.).
/// Produces a simple narrative by concatenating user messages and
/// extracting file paths and capability ids.
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
        let mut model_capability_names = Vec::new();

        for msg in messages {
            match msg {
                Message::User { content, .. } => {
                    let text = user_content_text(content);
                    if !text.is_empty() {
                        user_messages.push(truncate(&text, 200));
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
                            AssistantContent::Text { .. } => {}
                            AssistantContent::Thinking { .. } => {}
                        }
                    }
                }
                Message::CapabilityResult { .. } => {}
            }
        }

        let narrative = if user_messages.is_empty() {
            format!("({} messages summarized)", messages.len())
        } else {
            let mut parts = Vec::new();
            parts.push(format!("The user made {} requests.", user_messages.len()));
            parts.push(format!("Key requests: {}", user_messages.join("; ")));
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

        Ok(SummaryResult { narrative })
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

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::UserContent;
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
    async fn keyword_summarizer_empty_messages() {
        let summarizer = KeywordSummarizer;
        let result = summarizer.summarize(&[]).await.unwrap();
        assert!(result.narrative.contains("0 messages summarized"));
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
