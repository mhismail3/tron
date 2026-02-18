//! Summarizer trait and utilities for compaction.
//!
//! Defines the [`Summarizer`] trait used by the compaction engine, plus
//! a [`KeywordSummarizer`] fallback and message serialization utilities
//! for LLM-based summarization.
//!
//! The concrete LLM summarizer (which spawns a Haiku subagent) lives in
//! `llm_summarizer`, not here -- it depends on subsession infrastructure.
//! This module provides the trait and the tools it needs.

use serde_json::Value;

use tron_core::content::AssistantContent;
use tron_core::messages::{Message, ToolResultMessageContent, UserMessageContent};

use super::constants::{
    SUMMARIZER_ASSISTANT_TEXT_LIMIT, SUMMARIZER_MAX_SERIALIZED_CHARS,
    SUMMARIZER_THINKING_TEXT_LIMIT, SUMMARIZER_TOOL_RESULT_TEXT_LIMIT,
};
use super::types::{ExtractedData, KeyDecision, SummaryResult};

// =============================================================================
// Summarizer Trait
// =============================================================================

/// Trait for generating compaction summaries from conversation messages.
///
/// Implementations include:
/// - `LlmSummarizer` (in `llm_summarizer`) -- calls Haiku subagent
/// - [`KeywordSummarizer`] -- fast fallback using keyword extraction
#[async_trait::async_trait]
pub trait Summarizer: Send + Sync {
    /// Summarize a sequence of messages into a structured result.
    async fn summarize(
        &self,
        messages: &[Message],
    ) -> Result<SummaryResult, Box<dyn std::error::Error + Send + Sync>>;
}

/// Errors that can occur during summarization.
#[derive(Debug, thiserror::Error)]
pub enum SummarizerError {
    /// The LLM call timed out.
    #[error("summarizer timed out after {timeout_ms}ms")]
    Timeout {
        /// Timeout in milliseconds.
        timeout_ms: u64,
    },

    /// The LLM returned unparseable output.
    #[error("failed to parse summarizer response: {reason}")]
    ParseError {
        /// Why parsing failed.
        reason: String,
    },

    /// The LLM call failed.
    #[error("summarizer call failed: {message}")]
    CallFailed {
        /// Error message.
        message: String,
    },
}

// =============================================================================
// Keyword Summarizer (Fallback)
// =============================================================================

/// Fast fallback summarizer that extracts keywords from messages.
///
/// Used when the LLM summarizer fails (timeout, parse error, etc.).
/// Produces a simple narrative by concatenating user messages and
/// extracting file paths and tool names.
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
        let mut tool_names = Vec::new();

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
                            AssistantContent::ToolUse {
                                name, arguments, ..
                            } => {
                                if !tool_names.contains(name) {
                                    tool_names.push(name.clone());
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
                Message::ToolResult { .. } => {}
            }
        }

        let narrative = if user_messages.is_empty() {
            format!("({} messages summarized)", messages.len())
        } else {
            let mut parts = Vec::new();
            parts.push(format!("The user made {} requests.", user_messages.len()));
            parts.push(format!("Key requests: {}", user_messages.join("; ")));
            if !tool_names.is_empty() {
                parts.push(format!("Tools used: {}", tool_names.join(", ")));
            }
            if !files_modified.is_empty() {
                parts.push(format!("Files touched: {}", files_modified.join(", ")));
            }
            parts.join(" ")
        };

        Ok(SummaryResult {
            narrative,
            extracted_data: ExtractedData {
                current_goal: user_messages.first().cloned().unwrap_or_default(),
                completed_steps: Vec::new(),
                pending_tasks: Vec::new(),
                key_decisions: Vec::new(),
                files_modified,
                topics_discussed: topics,
                user_preferences: Vec::new(),
                important_context: Vec::new(),
                thinking_insights: Vec::new(),
            },
        })
    }
}

// =============================================================================
// Message Serialization
// =============================================================================

/// Serialize messages into a line-based transcript for the summarizer subagent.
///
/// Format:
/// ```text
/// [USER] text...
/// [ASSISTANT] text... (truncated to 300 chars)
/// [THINKING] thinking... (truncated to 500 chars)
/// [TOOL_CALL] name(key_args)
/// [TOOL_RESULT] text... (truncated to 100 chars)
/// [TOOL_ERROR] text...
/// ```
///
/// If the total transcript exceeds [`SUMMARIZER_MAX_SERIALIZED_CHARS`],
/// it keeps the first 25% and last 25%, inserting a middle marker.
#[must_use]
pub fn serialize_messages(messages: &[Message]) -> String {
    let mut lines = Vec::new();

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                let text = user_content_text(content);
                if !text.is_empty() {
                    lines.push(format!("[USER] {text}"));
                }
            }
            Message::Assistant { content, .. } => {
                for block in content {
                    match block {
                        AssistantContent::Text { text } => {
                            let t = truncate(text, SUMMARIZER_ASSISTANT_TEXT_LIMIT);
                            lines.push(format!("[ASSISTANT] {t}"));
                        }
                        AssistantContent::Thinking { thinking, .. } => {
                            if !thinking.is_empty() {
                                let t = truncate(thinking, SUMMARIZER_THINKING_TEXT_LIMIT);
                                lines.push(format!("[THINKING] {t}"));
                            }
                        }
                        AssistantContent::ToolUse {
                            name, arguments, ..
                        } => {
                            let args = extract_key_args(arguments);
                            if args.is_empty() {
                                lines.push(format!("[TOOL_CALL] {name}()"));
                            } else {
                                lines.push(format!("[TOOL_CALL] {name}({args})"));
                            }
                        }
                    }
                }
            }
            Message::ToolResult {
                content, is_error, ..
            } => {
                let text = tool_result_content_text(content);
                let t = truncate(&text, SUMMARIZER_TOOL_RESULT_TEXT_LIMIT);
                if *is_error == Some(true) {
                    lines.push(format!("[TOOL_ERROR] {t}"));
                } else {
                    lines.push(format!("[TOOL_RESULT] {t}"));
                }
            }
        }
    }

    let full = lines.join("\n");
    cap_transcript(&full, SUMMARIZER_MAX_SERIALIZED_CHARS)
}

/// Extract key arguments from a `tool_use` arguments map.
///
/// Looks for priority keys: `file_path`, `path`, `command`, `pattern`, `url`, `query`.
/// Each value is truncated to 100 chars.
fn extract_key_args(arguments: &serde_json::Map<String, Value>) -> String {
    const PRIORITY_KEYS: &[&str] = &["file_path", "path", "command", "pattern", "url", "query"];

    let mut parts = Vec::new();
    for &key in PRIORITY_KEYS {
        if let Some(val) = arguments.get(key) {
            let text = match val {
                Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            parts.push(format!("{key}: {}", truncate(&text, 100)));
        }
    }
    parts.join(", ")
}

/// Cap a transcript to a maximum character count.
///
/// If within limit, returns as-is. Otherwise, keeps the first 25% and
/// last 25%, inserting a `[... N characters omitted ...]` marker.
fn cap_transcript(text: &str, max_chars: usize) -> String {
    if text.len() <= max_chars {
        return text.to_string();
    }

    let quarter = max_chars / 4;
    // Snap to char boundaries so we don't split multi-byte characters.
    let head = tron_core::text::truncate_str(text, quarter);
    // For the tail, walk forward from the target start to find a char boundary.
    let tail_start = text.len().saturating_sub(quarter);
    let tail_boundary = text.ceil_char_boundary(tail_start);
    let tail = &text[tail_boundary..];
    let omitted = text.len().saturating_sub(head.len() + tail.len());

    format!("{head}\n[... {omitted} characters omitted ...]\n{tail}")
}

/// Truncate a string to a maximum length, appending "..." if truncated.
fn truncate(s: &str, max_len: usize) -> String {
    tron_core::text::truncate_with_suffix(s, max_len, "...")
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

/// Extract text from a `ToolResultMessageContent`.
fn tool_result_content_text(content: &ToolResultMessageContent) -> String {
    match content {
        ToolResultMessageContent::Text(t) => t.clone(),
        ToolResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                tron_core::content::ToolResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

// =============================================================================
// Response Parsing
// =============================================================================

/// Parse a JSON summarizer response into a [`SummaryResult`].
///
/// Expects the format:
/// ```json
/// {
///   "narrative": "...",
///   "extractedData": { ... }
/// }
/// ```
///
/// Strips markdown code fences if present.
pub fn parse_summarizer_response(response: &str) -> Result<SummaryResult, SummarizerError> {
    let cleaned = strip_code_fences(response);

    let parsed: Value =
        serde_json::from_str(&cleaned).map_err(|e| SummarizerError::ParseError {
            reason: format!("invalid JSON: {e}"),
        })?;

    let narrative = parsed
        .get("narrative")
        .and_then(Value::as_str)
        .ok_or_else(|| SummarizerError::ParseError {
            reason: "missing or invalid 'narrative' field".into(),
        })?;

    if narrative.is_empty() {
        return Err(SummarizerError::ParseError {
            reason: "'narrative' field is empty".into(),
        });
    }

    let extracted = parsed.get("extractedData").cloned().unwrap_or(Value::Null);
    let extracted_data = parse_extracted_data(&extracted);

    Ok(SummaryResult {
        narrative: narrative.to_string(),
        extracted_data,
    })
}

/// Parse the `extractedData` object from the summarizer response.
fn parse_extracted_data(value: &Value) -> ExtractedData {
    let obj = value.as_object();

    let get_string = |key: &str| -> String {
        obj.and_then(|o| o.get(key))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };

    let get_string_array = |key: &str| -> Vec<String> {
        obj.and_then(|o| o.get(key))
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(String::from)
                    .collect()
            })
            .unwrap_or_default()
    };

    let key_decisions = obj
        .and_then(|o| o.get("keyDecisions"))
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    let decision = v.get("decision")?.as_str()?.to_string();
                    let reason = v.get("reason")?.as_str()?.to_string();
                    Some(KeyDecision { decision, reason })
                })
                .collect()
        })
        .unwrap_or_default();

    ExtractedData {
        current_goal: get_string("currentGoal"),
        completed_steps: get_string_array("completedSteps"),
        pending_tasks: get_string_array("pendingTasks"),
        key_decisions,
        files_modified: get_string_array("filesModified"),
        topics_discussed: get_string_array("topicsDiscussed"),
        user_preferences: get_string_array("userPreferences"),
        important_context: get_string_array("importantContext"),
        thinking_insights: get_string_array("thinkingInsights"),
    }
}

/// Strip markdown code fences from a response string.
fn strip_code_fences(s: &str) -> String {
    let trimmed = s.trim();
    if let Some(rest) = trimmed.strip_prefix("```json") {
        rest.strip_suffix("```").unwrap_or(rest).trim().to_string()
    } else if let Some(rest) = trimmed.strip_prefix("```") {
        rest.strip_suffix("```").unwrap_or(rest).trim().to_string()
    } else {
        trimmed.to_string()
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tron_core::content::UserContent;

    // -- truncate --

    #[test]
    fn truncate_short_string_unchanged() {
        assert_eq!(truncate("hello", 10), "hello");
    }

    #[test]
    fn truncate_exact_length_unchanged() {
        assert_eq!(truncate("hello", 5), "hello");
    }

    #[test]
    fn truncate_long_string_adds_ellipsis() {
        let result = truncate("hello world", 8);
        assert!(result.ends_with("..."));
        assert!(result.len() <= 8);
    }

    // -- strip_code_fences --

    #[test]
    fn strip_json_code_fence() {
        let input = "```json\n{\"narrative\": \"test\"}\n```";
        assert_eq!(strip_code_fences(input), "{\"narrative\": \"test\"}");
    }

    #[test]
    fn strip_plain_code_fence() {
        let input = "```\n{\"narrative\": \"test\"}\n```";
        assert_eq!(strip_code_fences(input), "{\"narrative\": \"test\"}");
    }

    #[test]
    fn no_code_fence_passthrough() {
        let input = "{\"narrative\": \"test\"}";
        assert_eq!(strip_code_fences(input), input);
    }

    // -- cap_transcript --

    #[test]
    fn cap_transcript_within_limit() {
        let text = "short";
        assert_eq!(cap_transcript(text, 100), "short");
    }

    #[test]
    fn cap_transcript_exceeds_limit() {
        let text = "a".repeat(200);
        let result = cap_transcript(&text, 100);
        assert!(result.contains("[..."));
        assert!(result.contains("characters omitted"));
    }

    // -- extract_key_args --

    #[test]
    fn extract_key_args_file_path() {
        let mut map = serde_json::Map::new();
        let _ = map.insert("file_path".into(), json!("/src/main.rs"));
        assert_eq!(extract_key_args(&map), "file_path: /src/main.rs");
    }

    #[test]
    fn extract_key_args_multiple() {
        let mut map = serde_json::Map::new();
        let _ = map.insert("command".into(), json!("ls -la"));
        let _ = map.insert("path".into(), json!("/tmp"));
        let result = extract_key_args(&map);
        assert!(result.contains("path: /tmp"));
        assert!(result.contains("command: ls -la"));
    }

    #[test]
    fn extract_key_args_empty() {
        let map = serde_json::Map::new();
        assert_eq!(extract_key_args(&map), "");
    }

    #[test]
    fn extract_key_args_ignores_non_priority() {
        let mut map = serde_json::Map::new();
        let _ = map.insert("random_key".into(), json!("value"));
        assert_eq!(extract_key_args(&map), "");
    }

    #[test]
    fn extract_key_args_truncates_long_values() {
        let mut map = serde_json::Map::new();
        let _ = map.insert("command".into(), json!("a".repeat(200)));
        let result = extract_key_args(&map);
        assert!(result.len() < 200);
        assert!(result.contains("..."));
    }

    // -- serialize_messages --

    #[test]
    fn serialize_user_message() {
        let messages = vec![Message::user("Hello world")];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[USER] Hello world");
    }

    #[test]
    fn serialize_assistant_text() {
        let messages = vec![Message::assistant("Response text")];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[ASSISTANT] Response text");
    }

    #[test]
    fn serialize_tool_use() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("file_path".into(), json!("/src/main.rs"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "tc-1".into(),
                name: "read".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[TOOL_CALL] read(file_path: /src/main.rs)");
    }

    #[test]
    fn serialize_tool_result() {
        let messages = vec![Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("file contents here".into()),
            is_error: None,
        }];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[TOOL_RESULT] file contents here");
    }

    #[test]
    fn serialize_tool_error() {
        let messages = vec![Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("permission denied".into()),
            is_error: Some(true),
        }];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[TOOL_ERROR] permission denied");
    }

    #[test]
    fn serialize_thinking_block() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::Thinking {
                thinking: "Let me reason about this...".into(),
                signature: Some("sig".into()),
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&messages);
        assert_eq!(result, "[THINKING] Let me reason about this...");
    }

    #[test]
    fn serialize_empty_thinking_skipped() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::Thinking {
                thinking: String::new(),
                signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = serialize_messages(&messages);
        assert!(result.is_empty());
    }

    #[test]
    fn serialize_multiple_messages() {
        let messages = vec![
            Message::user("Write a function"),
            Message::assistant("Here's the function:"),
        ];
        let result = serialize_messages(&messages);
        assert!(result.contains("[USER] Write a function"));
        assert!(result.contains("[ASSISTANT] Here's the function:"));
    }

    #[test]
    fn serialize_truncates_long_assistant_text() {
        let long_text = "a".repeat(500);
        let messages = vec![Message::assistant(&long_text)];
        let result = serialize_messages(&messages);
        assert!(result.len() < 500);
        assert!(result.contains("..."));
    }

    #[test]
    fn serialize_caps_at_max_chars() {
        let long_text = "a".repeat(1000);
        let messages: Vec<Message> = (0..200).map(|_| Message::user(&long_text)).collect();
        let result = serialize_messages(&messages);
        assert!(result.len() <= SUMMARIZER_MAX_SERIALIZED_CHARS + 100);
        assert!(result.contains("[...]") || result.len() <= SUMMARIZER_MAX_SERIALIZED_CHARS);
    }

    // -- parse_summarizer_response --

    #[test]
    fn parse_valid_response() {
        let response = r#"{
            "narrative": "The user asked to implement feature X.",
            "extractedData": {
                "currentGoal": "Implement feature X",
                "completedSteps": ["Step 1", "Step 2"],
                "filesModified": ["src/main.rs"]
            }
        }"#;
        let result = parse_summarizer_response(response).unwrap();
        assert_eq!(result.narrative, "The user asked to implement feature X.");
        assert_eq!(result.extracted_data.current_goal, "Implement feature X");
        assert_eq!(result.extracted_data.completed_steps.len(), 2);
        assert_eq!(result.extracted_data.files_modified.len(), 1);
    }

    #[test]
    fn parse_response_with_code_fences() {
        let response = "```json\n{\"narrative\": \"summary\", \"extractedData\": {}}\n```";
        let result = parse_summarizer_response(response).unwrap();
        assert_eq!(result.narrative, "summary");
    }

    #[test]
    fn parse_response_missing_narrative() {
        let response = r#"{"extractedData": {}}"#;
        let err = parse_summarizer_response(response).unwrap_err();
        assert!(matches!(err, SummarizerError::ParseError { .. }));
    }

    #[test]
    fn parse_response_empty_narrative() {
        let response = r#"{"narrative": "", "extractedData": {}}"#;
        let err = parse_summarizer_response(response).unwrap_err();
        assert!(matches!(err, SummarizerError::ParseError { .. }));
    }

    #[test]
    fn parse_response_invalid_json() {
        let err = parse_summarizer_response("not json").unwrap_err();
        assert!(matches!(err, SummarizerError::ParseError { .. }));
    }

    #[test]
    fn parse_response_missing_extracted_data() {
        let response = r#"{"narrative": "summary"}"#;
        let result = parse_summarizer_response(response).unwrap();
        assert_eq!(result.narrative, "summary");
        assert!(result.extracted_data.current_goal.is_empty());
    }

    #[test]
    fn parse_response_key_decisions() {
        let response = r#"{
            "narrative": "summary",
            "extractedData": {
                "keyDecisions": [
                    {"decision": "Use Rust", "reason": "Performance"},
                    {"decision": "Use SQLite", "reason": "Simplicity"}
                ]
            }
        }"#;
        let result = parse_summarizer_response(response).unwrap();
        assert_eq!(result.extracted_data.key_decisions.len(), 2);
        assert_eq!(result.extracted_data.key_decisions[0].decision, "Use Rust");
    }

    #[test]
    fn parse_response_omits_empty_arrays() {
        let response = r#"{"narrative": "summary", "extractedData": {"currentGoal": "test"}}"#;
        let result = parse_summarizer_response(response).unwrap();
        assert!(result.extracted_data.completed_steps.is_empty());
        assert!(result.extracted_data.pending_tasks.is_empty());
    }

    // -- KeywordSummarizer --

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
                content: vec![AssistantContent::ToolUse {
                    id: "tc-1".into(),
                    name: "read".into(),
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

    // -- User content helpers --

    #[test]
    fn serialize_user_with_blocks() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text {
                    text: "First block".into(),
                },
                UserContent::Text {
                    text: "Second block".into(),
                },
            ]),
            timestamp: None,
        }];
        let result = serialize_messages(&messages);
        assert!(result.contains("[USER]"));
        assert!(result.contains("First block"));
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

    // -- tool_result_content_text --

    #[test]
    fn tool_result_content_text_from_string() {
        let content = ToolResultMessageContent::Text("output".into());
        assert_eq!(tool_result_content_text(&content), "output");
    }

    #[test]
    fn tool_result_content_text_from_blocks() {
        let content = ToolResultMessageContent::Blocks(vec![
            tron_core::content::ToolResultContent::text("line1"),
            tron_core::content::ToolResultContent::text("line2"),
        ]);
        assert_eq!(tool_result_content_text(&content), "line1\nline2");
    }
}
