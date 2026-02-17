//! LLM-based summarizer.
//!
//! Spawns a subagent (Haiku) for intelligent context summarization.
//! Falls back to [`KeywordSummarizer`] on any failure.
//!
//! Uses [`serialize_messages`](crate::summarizer::serialize_messages) and
//! [`parse_summarizer_response`](crate::summarizer::parse_summarizer_response)
//! from the shared summarizer module.

use async_trait::async_trait;
use tracing::warn;

use tron_core::messages::Message;

use super::summarizer::{
    parse_summarizer_response, serialize_messages, KeywordSummarizer, Summarizer,
};
use super::types::SummaryResult;

// =============================================================================
// Types
// =============================================================================

/// Result of spawning a summarizer subsession.
#[derive(Clone, Debug)]
pub struct SubsessionResult {
    /// Whether the subsession succeeded.
    pub success: bool,
    /// Output text from the subsession.
    pub output: Option<String>,
    /// Error message if failed.
    pub error: Option<String>,
}

/// Dependency for spawning a summarizer subsession.
///
/// Abstracted as a trait for testability.
#[async_trait]
pub trait SubsessionSpawner: Send + Sync {
    /// Spawn a summarizer subsession with the given task transcript.
    async fn spawn_summarizer(&self, task: &str) -> SubsessionResult;
}

// =============================================================================
// LlmSummarizer
// =============================================================================

/// LLM-based summarizer that spawns a subagent for intelligent summaries.
///
/// On any failure (subsession error, invalid JSON, missing narrative),
/// falls back to [`KeywordSummarizer`].
pub struct LlmSummarizer<S: SubsessionSpawner> {
    spawner: S,
    fallback: KeywordSummarizer,
}

impl<S: SubsessionSpawner> LlmSummarizer<S> {
    /// Create a new LLM summarizer with the given subsession spawner.
    pub fn new(spawner: S) -> Self {
        Self {
            spawner,
            fallback: KeywordSummarizer,
        }
    }
}

#[async_trait]
impl<S: SubsessionSpawner> Summarizer for LlmSummarizer<S> {
    async fn summarize(
        &self,
        messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>> {
        let serialized = serialize_messages(messages);

        let result = self.spawner.spawn_summarizer(&serialized).await;

        let output = match result {
            ref r if r.success => r.output.clone(),
            _ => None,
        };
        let Some(output) = output else {
            warn!(
                error = result.error.as_deref().unwrap_or("unknown"),
                "LLM summarizer subagent failed, using fallback"
            );
            return self.fallback.summarize(messages).await;
        };
        if let Ok(parsed) = parse_summarizer_response(&output) {
            Ok(parsed)
        } else {
            warn!(
                output_length = output.len(),
                "LLM summarizer returned invalid JSON, using fallback"
            );
            self.fallback.summarize(messages).await
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::content::AssistantContent;
    use tron_core::messages::{ToolResultMessageContent, UserMessageContent};

    use crate::context::constants::{
        SUMMARIZER_ASSISTANT_TEXT_LIMIT, SUMMARIZER_MAX_SERIALIZED_CHARS,
        SUMMARIZER_TOOL_RESULT_TEXT_LIMIT,
    };

    // -- serialize_messages (delegates to summarizer module, verify integration) --

    #[test]
    fn serialize_empty_messages() {
        let result = serialize_messages(&[]);
        assert!(result.is_empty());
    }

    #[test]
    fn serialize_user_text_message() {
        let msgs = [Message::user("Hello world")];
        let result = serialize_messages(&msgs);
        assert_eq!(result, "[USER] Hello world");
    }

    #[test]
    fn serialize_assistant_text_truncated() {
        let long_text = "a".repeat(500);
        let msgs = [Message::assistant(&long_text)];
        let result = serialize_messages(&msgs);
        assert!(result.contains("[ASSISTANT]"));
        let content = result.strip_prefix("[ASSISTANT] ").unwrap();
        assert_eq!(content.len(), SUMMARIZER_ASSISTANT_TEXT_LIMIT);
    }

    #[test]
    fn serialize_thinking_block() {
        let msgs = [Message::Assistant {
            content: vec![AssistantContent::Thinking {
                thinking: "I need to think about this carefully".into(),
                signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&msgs);
        assert!(result.starts_with("[THINKING] I need to think"));
    }

    #[test]
    fn serialize_thinking_empty_skipped() {
        let msgs = [Message::Assistant {
            content: vec![AssistantContent::Thinking {
                thinking: String::new(),
                signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&msgs);
        assert!(result.is_empty());
    }

    #[test]
    fn serialize_tool_call() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("file_path".into(), serde_json::json!("/src/main.rs"));
        let _ = args.insert("command".into(), serde_json::json!("build"));
        let msgs = [Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "tc-1".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&msgs);
        assert!(result.starts_with("[TOOL_CALL] bash("));
        assert!(result.contains("file_path: /src/main.rs"));
    }

    #[test]
    fn serialize_tool_result() {
        let msgs = [Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("File content here".into()),
            is_error: None,
        }];
        let result = serialize_messages(&msgs);
        assert!(result.starts_with("[TOOL_RESULT] File content"));
    }

    #[test]
    fn serialize_tool_error() {
        let msgs = [Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("Permission denied".into()),
            is_error: Some(true),
        }];
        let result = serialize_messages(&msgs);
        assert!(result.starts_with("[TOOL_ERROR] Permission denied"));
    }

    #[test]
    fn serialize_tool_result_truncated() {
        let long = "x".repeat(500);
        let msgs = [Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text(long),
            is_error: None,
        }];
        let result = serialize_messages(&msgs);
        let content = result.strip_prefix("[TOOL_RESULT] ").unwrap();
        assert_eq!(content.len(), SUMMARIZER_TOOL_RESULT_TEXT_LIMIT);
    }

    #[test]
    fn serialize_truncates_large_output() {
        let big_text = "a".repeat(200);
        let msgs: Vec<Message> = (0..1000).map(|_| Message::user(&big_text)).collect();
        let result = serialize_messages(&msgs);
        assert!(result.len() <= SUMMARIZER_MAX_SERIALIZED_CHARS + 200);
        assert!(result.contains("characters omitted"));
    }

    #[test]
    fn serialize_mixed_conversation() {
        let msgs = vec![
            Message::user("Hello"),
            Message::assistant("Hi there"),
            Message::user("Run a command"),
        ];
        let result = serialize_messages(&msgs);
        let lines: Vec<&str> = result.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("[USER]"));
        assert!(lines[1].starts_with("[ASSISTANT]"));
        assert!(lines[2].starts_with("[USER]"));
    }

    // -- parse_summarizer_response (delegates to summarizer module) --

    #[test]
    fn parse_valid_json_response() {
        let raw = r#"{"narrative": "Summary text", "extractedData": {"currentGoal": "Fix bug"}}"#;
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.narrative, "Summary text");
        assert_eq!(result.extracted_data.current_goal, "Fix bug");
    }

    #[test]
    fn parse_response_with_code_fences() {
        let raw = "```json\n{\"narrative\": \"Summary\"}\n```";
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.narrative, "Summary");
    }

    #[test]
    fn parse_response_without_extracted_data() {
        let raw = r#"{"narrative": "Just a summary"}"#;
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.narrative, "Just a summary");
        assert!(result.extracted_data.current_goal.is_empty());
    }

    #[test]
    fn parse_response_empty_narrative_returns_err() {
        let raw = r#"{"narrative": ""}"#;
        assert!(parse_summarizer_response(raw).is_err());
    }

    #[test]
    fn parse_response_missing_narrative_returns_err() {
        let raw = r#"{"summary": "text"}"#;
        assert!(parse_summarizer_response(raw).is_err());
    }

    #[test]
    fn parse_response_invalid_json_returns_err() {
        assert!(parse_summarizer_response("not json at all").is_err());
    }

    #[test]
    fn parse_response_with_extracted_data_fields() {
        let raw = r#"{
            "narrative": "Summary",
            "extractedData": {
                "currentGoal": "Implement auth",
                "completedSteps": ["step 1", "step 2"],
                "pendingTasks": ["task 1"],
                "keyDecisions": [{"decision": "Use JWT", "reason": "Stateless"}],
                "filesModified": ["auth.rs"],
                "topicsDiscussed": ["security"],
                "userPreferences": ["prefer Rust"],
                "importantContext": ["deadline tomorrow"],
                "thinkingInsights": ["complex flow"]
            }
        }"#;
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.extracted_data.current_goal, "Implement auth");
        assert_eq!(result.extracted_data.completed_steps.len(), 2);
        assert_eq!(result.extracted_data.pending_tasks, vec!["task 1"]);
        assert_eq!(result.extracted_data.key_decisions.len(), 1);
        assert_eq!(result.extracted_data.key_decisions[0].decision, "Use JWT");
        assert_eq!(result.extracted_data.files_modified, vec!["auth.rs"]);
        assert_eq!(result.extracted_data.topics_discussed, vec!["security"]);
    }

    #[test]
    fn parse_response_normalizes_missing_fields() {
        let raw = r#"{"narrative": "Summary", "extractedData": {"currentGoal": "Fix"}}"#;
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.extracted_data.current_goal, "Fix");
        assert!(result.extracted_data.completed_steps.is_empty());
        assert!(result.extracted_data.key_decisions.is_empty());
    }

    #[test]
    fn parse_response_filters_invalid_decision_entries() {
        let raw = r#"{
            "narrative": "Summary",
            "extractedData": {
                "keyDecisions": [
                    {"decision": "A", "reason": "B"},
                    {"decision": "C"},
                    "not an object"
                ]
            }
        }"#;
        let result = parse_summarizer_response(raw).unwrap();
        assert_eq!(result.extracted_data.key_decisions.len(), 1);
    }

    // -- LlmSummarizer with mock --

    struct MockSpawner {
        result: SubsessionResult,
    }

    #[async_trait]
    impl SubsessionSpawner for MockSpawner {
        async fn spawn_summarizer(&self, _task: &str) -> SubsessionResult {
            self.result.clone()
        }
    }

    #[tokio::test]
    async fn llm_summarizer_success() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: true,
                output: Some(r#"{"narrative": "LLM summary"}"#.into()),
                error: None,
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert_eq!(result.narrative, "LLM summary");
    }

    #[tokio::test]
    async fn llm_summarizer_fallback_on_failure() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: false,
                output: None,
                error: Some("timeout".into()),
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert!(result.narrative.contains("1 requests"));
    }

    #[tokio::test]
    async fn llm_summarizer_fallback_on_invalid_json() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: true,
                output: Some("not json".into()),
                error: None,
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert!(result.narrative.contains("1 requests"));
    }

    #[tokio::test]
    async fn llm_summarizer_fallback_on_no_output() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: true,
                output: None,
                error: None,
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert!(result.narrative.contains("1 requests"));
    }

    #[tokio::test]
    async fn llm_summarizer_with_code_fences() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: true,
                output: Some(
                    "```json\n{\"narrative\": \"Fenced summary\"}\n```".into(),
                ),
                error: None,
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert_eq!(result.narrative, "Fenced summary");
    }

    #[tokio::test]
    async fn llm_summarizer_with_extracted_data() {
        let spawner = MockSpawner {
            result: SubsessionResult {
                success: true,
                output: Some(
                    r#"{"narrative": "Summary", "extractedData": {"currentGoal": "Fix auth"}}"#
                        .into(),
                ),
                error: None,
            },
        };
        let summarizer = LlmSummarizer::new(spawner);
        let result = summarizer
            .summarize(&[Message::user("test")])
            .await
            .unwrap();
        assert_eq!(result.narrative, "Summary");
        assert_eq!(result.extracted_data.current_goal, "Fix auth");
    }

    #[tokio::test]
    async fn llm_summarizer_passes_serialized_transcript() {
        use std::sync::{Arc, Mutex};

        struct CapturingSpawner {
            captured: Arc<Mutex<Option<String>>>,
        }

        #[async_trait]
        impl SubsessionSpawner for CapturingSpawner {
            async fn spawn_summarizer(&self, task: &str) -> SubsessionResult {
                *self.captured.lock().unwrap() = Some(task.to_owned());
                SubsessionResult {
                    success: true,
                    output: Some(r#"{"narrative": "ok"}"#.into()),
                    error: None,
                }
            }
        }

        let captured = Arc::new(Mutex::new(None));
        let spawner = CapturingSpawner {
            captured: captured.clone(),
        };
        let summarizer = LlmSummarizer::new(spawner);
        let _ = summarizer
            .summarize(&[Message::user("Hello"), Message::assistant("Hi")])
            .await
            .unwrap();

        let task = captured.lock().unwrap().clone().unwrap();
        assert!(task.contains("[USER] Hello"));
        assert!(task.contains("[ASSISTANT] Hi"));
    }

    // -- UserMessageContent::Blocks (ensure serialize handles blocks) --

    #[test]
    fn serialize_user_with_blocks() {
        let msgs = [Message::User {
            content: UserMessageContent::Blocks(vec![
                tron_core::content::UserContent::Text {
                    text: "First block".into(),
                },
                tron_core::content::UserContent::Text {
                    text: "Second block".into(),
                },
            ]),
            timestamp: None,
        }];
        let result = serialize_messages(&msgs);
        assert!(result.contains("[USER]"));
        assert!(result.contains("First block"));
        assert!(result.contains("Second block"));
    }
}
