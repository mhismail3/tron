//! Context snapshot builder.
//!
//! Generates [`ContextSnapshot`] and [`DetailedContextSnapshot`] from injected
//! dependencies. Pure read-only — never modifies state.

use tron_core::content::AssistantContent;
use tron_core::messages::Message;

use crate::token_estimator::estimate_message_tokens;
use crate::types::{
    ContextSnapshot, DetailedContextSnapshot, DetailedMessageInfo, ThresholdLevel, TokenBreakdown,
    ToolCallInfo,
};

// =============================================================================
// Dependencies trait
// =============================================================================

/// Injected dependencies from the context manager.
///
/// Allows the builder to query current state without owning it.
pub trait SnapshotDeps: Send + Sync {
    /// API-reported token count, or component-sum estimate.
    fn get_current_tokens(&self) -> u64;
    /// Model's context limit.
    fn get_context_limit(&self) -> u64;
    /// Current messages.
    fn get_messages(&self) -> Vec<Message>;
    /// Estimated system prompt tokens.
    fn estimate_system_prompt_tokens(&self) -> u64;
    /// Estimated tools tokens.
    fn estimate_tools_tokens(&self) -> u64;
    /// Estimated rules tokens.
    fn estimate_rules_tokens(&self) -> u64;
    /// Total message tokens from the message store.
    fn get_messages_tokens(&self) -> u64;
    /// Token estimate for a single message.
    fn get_message_tokens(&self, msg: &Message) -> u64;
    /// The effective system prompt text.
    fn get_system_prompt(&self) -> String;
    /// Tool clarification text (Codex mode).
    fn get_tool_clarification(&self) -> Option<String>;
    /// Tool names for the detailed snapshot.
    fn get_tool_names(&self) -> Vec<String>;
}

// =============================================================================
// ContextSnapshotBuilder
// =============================================================================

/// Builds context snapshots from injected dependencies.
pub struct ContextSnapshotBuilder<D: SnapshotDeps> {
    deps: D,
}

impl<D: SnapshotDeps> ContextSnapshotBuilder<D> {
    /// Create a new snapshot builder with the given dependencies.
    pub fn new(deps: D) -> Self {
        Self { deps }
    }

    /// Build a basic context snapshot.
    #[must_use]
    pub fn build(&self) -> ContextSnapshot {
        let current_tokens = self.deps.get_current_tokens();
        let context_limit = self.deps.get_context_limit();

        #[allow(clippy::cast_precision_loss)]
        let usage_percent = if context_limit > 0 {
            current_tokens as f64 / context_limit as f64
        } else {
            0.0
        };

        let threshold_level = ThresholdLevel::from_ratio(usage_percent);

        ContextSnapshot {
            current_tokens,
            context_limit,
            usage_percent,
            threshold_level,
            breakdown: TokenBreakdown {
                system_prompt: self.deps.estimate_system_prompt_tokens(),
                tools: self.deps.estimate_tools_tokens(),
                rules: self.deps.estimate_rules_tokens(),
                messages: self.deps.get_messages_tokens(),
            },
            rules: None,
        }
    }

    /// Build a detailed snapshot with per-message breakdown.
    #[must_use]
    pub fn build_detailed(&self) -> DetailedContextSnapshot {
        let snapshot = self.build();
        let messages = self.deps.get_messages();

        let detailed_messages: Vec<DetailedMessageInfo> = messages
            .iter()
            .enumerate()
            .map(|(index, msg)| build_message_info(msg, index, self.deps.get_message_tokens(msg)))
            .collect();

        DetailedContextSnapshot {
            snapshot,
            messages: detailed_messages,
            system_prompt_content: self.deps.get_system_prompt(),
            tool_clarification_content: self.deps.get_tool_clarification(),
            tools_content: self.deps.get_tool_names(),
        }
    }
}

// =============================================================================
// Message info builder
// =============================================================================

fn build_message_info(msg: &Message, index: usize, tokens: u64) -> DetailedMessageInfo {
    match msg {
        Message::User { content, .. } => {
            let text = match content {
                tron_core::messages::UserMessageContent::Text(t) => t.clone(),
                tron_core::messages::UserMessageContent::Blocks(blocks) => blocks
                    .iter()
                    .filter_map(|b| b.as_text())
                    .collect::<Vec<_>>()
                    .join("\n"),
            };
            DetailedMessageInfo {
                index,
                role: "user".into(),
                tokens,
                summary: summarize_content(&text, 100),
                content: text,
                event_id: None,
                tool_calls: None,
                tool_call_id: None,
                is_error: None,
            }
        }
        Message::Assistant { content, .. } => {
            let mut text_parts = Vec::new();
            let mut tool_calls = Vec::new();

            for block in content {
                match block {
                    AssistantContent::Text { text } => {
                        text_parts.push(text.clone());
                    }
                    AssistantContent::ToolUse {
                        id,
                        name,
                        arguments,
                        ..
                    } => {
                        let args_str = serde_json::to_string(arguments).unwrap_or_default();
                        tool_calls.push(ToolCallInfo {
                            id: id.clone(),
                            name: name.clone(),
                            tokens: u64::from(estimate_message_tokens(msg)),
                            arguments: args_str,
                        });
                    }
                    AssistantContent::Thinking { .. } => {}
                }
            }

            let full_text = text_parts.join("\n");
            DetailedMessageInfo {
                index,
                role: "assistant".into(),
                tokens,
                summary: summarize_content(&full_text, 100),
                content: full_text,
                event_id: None,
                tool_calls: if tool_calls.is_empty() {
                    None
                } else {
                    Some(tool_calls)
                },
                tool_call_id: None,
                is_error: None,
            }
        }
        Message::ToolResult {
            tool_call_id,
            content,
            is_error,
        } => {
            let text = match content {
                tron_core::messages::ToolResultMessageContent::Text(t) => t.clone(),
                tron_core::messages::ToolResultMessageContent::Blocks(blocks) => blocks
                    .iter()
                    .filter_map(|b| match b {
                        tron_core::content::ToolResultContent::Text { text } => {
                            Some(text.as_str())
                        }
                        tron_core::content::ToolResultContent::Image { .. } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            };
            DetailedMessageInfo {
                index,
                role: "tool_result".into(),
                tokens,
                summary: summarize_content(&text, 100),
                content: text,
                event_id: None,
                tool_calls: None,
                tool_call_id: Some(tool_call_id.clone()),
                is_error: *is_error,
            }
        }
    }
}

/// Truncate content for display, appending "..." if truncated.
fn summarize_content(text: &str, max_len: usize) -> String {
    tron_core::text::truncate_with_suffix(text, max_len, "...")
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::messages::{ToolResultMessageContent, UserMessageContent};

    struct MockDeps {
        current_tokens: u64,
        context_limit: u64,
        messages: Vec<Message>,
        system_prompt_tokens: u64,
        tools_tokens: u64,
        rules_tokens: u64,
        messages_tokens: u64,
        message_token_value: u64,
    }

    impl Default for MockDeps {
        fn default() -> Self {
            Self {
                current_tokens: 50_000,
                context_limit: 100_000,
                messages: vec![Message::user("Hello"), Message::assistant("Hi there")],
                system_prompt_tokens: 2_000,
                tools_tokens: 1_000,
                rules_tokens: 500,
                messages_tokens: 5_000,
                message_token_value: 100,
            }
        }
    }

    impl SnapshotDeps for MockDeps {
        fn get_current_tokens(&self) -> u64 {
            self.current_tokens
        }
        fn get_context_limit(&self) -> u64 {
            self.context_limit
        }
        fn get_messages(&self) -> Vec<Message> {
            self.messages.clone()
        }
        fn estimate_system_prompt_tokens(&self) -> u64 {
            self.system_prompt_tokens
        }
        fn estimate_tools_tokens(&self) -> u64 {
            self.tools_tokens
        }
        fn estimate_rules_tokens(&self) -> u64 {
            self.rules_tokens
        }
        fn get_messages_tokens(&self) -> u64 {
            self.messages_tokens
        }
        fn get_message_tokens(&self, _msg: &Message) -> u64 {
            self.message_token_value
        }
        fn get_system_prompt(&self) -> String {
            "You are a helpful assistant.".into()
        }
        fn get_tool_clarification(&self) -> Option<String> {
            None
        }
        fn get_tool_names(&self) -> Vec<String> {
            vec!["bash".into(), "read".into()]
        }
    }

    // -- build --

    #[test]
    fn build_basic_snapshot() {
        let deps = MockDeps::default();
        let builder = ContextSnapshotBuilder::new(deps);
        let snap = builder.build();
        assert_eq!(snap.current_tokens, 50_000);
        assert_eq!(snap.context_limit, 100_000);
        assert!((snap.usage_percent - 0.5).abs() < f64::EPSILON);
        assert_eq!(snap.threshold_level, ThresholdLevel::Warning);
    }

    #[test]
    fn build_breakdown_values() {
        let deps = MockDeps::default();
        let builder = ContextSnapshotBuilder::new(deps);
        let snap = builder.build();
        assert_eq!(snap.breakdown.system_prompt, 2_000);
        assert_eq!(snap.breakdown.tools, 1_000);
        assert_eq!(snap.breakdown.rules, 500);
        assert_eq!(snap.breakdown.messages, 5_000);
    }

    #[test]
    fn build_zero_limit() {
        let deps = MockDeps {
            context_limit: 0,
            ..MockDeps::default()
        };
        let builder = ContextSnapshotBuilder::new(deps);
        let snap = builder.build();
        assert!((snap.usage_percent - 0.0).abs() < f64::EPSILON);
        assert_eq!(snap.threshold_level, ThresholdLevel::Normal);
    }

    // -- build_detailed --

    #[test]
    fn build_detailed_snapshot() {
        let deps = MockDeps::default();
        let builder = ContextSnapshotBuilder::new(deps);
        let detailed = builder.build_detailed();
        assert_eq!(detailed.messages.len(), 2);
        assert_eq!(detailed.messages[0].role, "user");
        assert_eq!(detailed.messages[1].role, "assistant");
        assert_eq!(detailed.system_prompt_content, "You are a helpful assistant.");
        assert!(detailed.tool_clarification_content.is_none());
        assert_eq!(detailed.tools_content, vec!["bash", "read"]);
    }

    #[test]
    fn detailed_message_has_correct_indices() {
        let deps = MockDeps::default();
        let builder = ContextSnapshotBuilder::new(deps);
        let detailed = builder.build_detailed();
        assert_eq!(detailed.messages[0].index, 0);
        assert_eq!(detailed.messages[1].index, 1);
    }

    #[test]
    fn detailed_message_tokens_from_deps() {
        let deps = MockDeps {
            message_token_value: 42,
            ..MockDeps::default()
        };
        let builder = ContextSnapshotBuilder::new(deps);
        let detailed = builder.build_detailed();
        assert_eq!(detailed.messages[0].tokens, 42);
    }

    // -- build_message_info --

    #[test]
    fn user_message_info() {
        let msg = Message::user("Hello world");
        let info = build_message_info(&msg, 0, 50);
        assert_eq!(info.role, "user");
        assert_eq!(info.content, "Hello world");
        assert_eq!(info.tokens, 50);
        assert!(info.tool_calls.is_none());
        assert!(info.tool_call_id.is_none());
    }

    #[test]
    fn assistant_message_info() {
        let msg = Message::assistant("Response text");
        let info = build_message_info(&msg, 1, 30);
        assert_eq!(info.role, "assistant");
        assert_eq!(info.content, "Response text");
    }

    #[test]
    fn assistant_with_tool_calls() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), serde_json::json!("ls"));
        let msg = Message::Assistant {
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
        };
        let info = build_message_info(&msg, 2, 80);
        assert!(info.tool_calls.is_some());
        let calls = info.tool_calls.unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].name, "bash");
        assert!(calls[0].arguments.contains("ls"));
    }

    #[test]
    fn tool_result_message_info() {
        let msg = Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("file contents".into()),
            is_error: Some(false),
        };
        let info = build_message_info(&msg, 3, 20);
        assert_eq!(info.role, "tool_result");
        assert_eq!(info.tool_call_id, Some("tc-1".into()));
        assert_eq!(info.is_error, Some(false));
    }

    #[test]
    fn tool_result_error_flag() {
        let msg = Message::ToolResult {
            tool_call_id: "tc-2".into(),
            content: ToolResultMessageContent::Text("error".into()),
            is_error: Some(true),
        };
        let info = build_message_info(&msg, 0, 10);
        assert_eq!(info.is_error, Some(true));
    }

    #[test]
    fn user_blocks_message_info() {
        let msg = Message::User {
            content: UserMessageContent::Blocks(vec![
                tron_core::content::UserContent::Text {
                    text: "part one".into(),
                },
                tron_core::content::UserContent::Text {
                    text: "part two".into(),
                },
            ]),
            timestamp: None,
        };
        let info = build_message_info(&msg, 0, 50);
        assert!(info.content.contains("part one"));
        assert!(info.content.contains("part two"));
    }

    // -- summarize_content --

    #[test]
    fn summarize_short_content() {
        assert_eq!(summarize_content("hello", 10), "hello");
    }

    #[test]
    fn summarize_long_content() {
        let long = "a".repeat(200);
        let result = summarize_content(&long, 50);
        assert!(result.ends_with("..."));
        assert!(result.len() <= 50);
    }

    #[test]
    fn summarize_multibyte_boundary() {
        // Em dash '—' is 3 bytes (U+2014). If the truncation point lands
        // inside a multi-byte char, we must snap to the preceding char boundary.
        let text = "a".repeat(95) + "—quiet work"; // byte 95..98 is '—'
        let result = summarize_content(&text, 100);
        assert!(result.ends_with("..."));
        // Must not panic, and boundary should be before the em dash
        assert!(!result.contains('—'));
    }

    // -- ThresholdLevel::from_ratio --

    #[test]
    fn threshold_normal() {
        assert_eq!(ThresholdLevel::from_ratio(0.3), ThresholdLevel::Normal);
    }

    #[test]
    fn threshold_warning() {
        assert_eq!(ThresholdLevel::from_ratio(0.5), ThresholdLevel::Warning);
    }

    #[test]
    fn threshold_alert() {
        assert_eq!(ThresholdLevel::from_ratio(0.7), ThresholdLevel::Alert);
    }

    #[test]
    fn threshold_critical() {
        assert_eq!(ThresholdLevel::from_ratio(0.85), ThresholdLevel::Critical);
    }

    #[test]
    fn threshold_exceeded() {
        assert_eq!(ThresholdLevel::from_ratio(0.95), ThresholdLevel::Exceeded);
    }
}
