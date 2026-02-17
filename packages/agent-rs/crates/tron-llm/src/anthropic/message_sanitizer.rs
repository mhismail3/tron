//! # Message Sanitizer
//!
//! Pre-conversion sanitization for messages before they're sent to the Anthropic API.
//! Ports phases 1–4 from the TypeScript `sanitizeMessages()`.
//!
//! Invariants enforced:
//! 1. Every `tool_use` block has a corresponding `ToolResult` message
//! 2. No empty messages
//! 3. No thinking-only assistant messages (display-only, no signature)
//! 4. First message is user role
//!
//! This is idempotent: `sanitize(sanitize(x)) == sanitize(x)`.

use std::collections::{HashMap, HashSet};

use tracing::warn;

use tron_core::content::AssistantContent;
use tron_core::messages::{Message, ToolResultMessageContent};

/// Content for synthetic tool results when execution was interrupted.
const INTERRUPTED_CONTENT: &str = "[Interrupted]";

/// Content for placeholder user message when conversation doesn't start with user.
const CONTINUED_CONTENT: &str = "[Continued]";

/// Sanitize messages to guarantee API compliance.
///
/// Returns a new `Vec<Message>` with fixes applied:
/// - Empty messages filtered out
/// - Thinking-only assistant messages (no signature) filtered out
/// - Duplicate tool_use IDs deduplicated
/// - Synthetic tool results injected for unmatched tool_use blocks
/// - Placeholder user message prepended if first message isn't user
pub fn sanitize_messages(messages: Vec<Message>) -> Vec<Message> {
    // PHASE 1: Filter invalid messages, deduplicate tool_use IDs
    let mut valid: Vec<Message> = Vec::with_capacity(messages.len());
    let mut seen_tool_use_ids: HashSet<String> = HashSet::new();
    // tool_use_id → index in `valid` where the assistant message lives
    let mut tool_use_locations: HashMap<String, usize> = HashMap::new();

    for msg in messages {
        match &msg {
            Message::User { content, .. } => {
                if !is_valid_user_content(content) {
                    warn!("Removed empty user message");
                    continue;
                }
                valid.push(msg);
            }
            Message::Assistant { content, .. } => {
                // Filter out duplicate tool_use blocks
                let mut filtered: Vec<AssistantContent> = Vec::with_capacity(content.len());
                for block in content {
                    if let AssistantContent::ToolUse { id, .. } = block {
                        if seen_tool_use_ids.contains(id) {
                            warn!(tool_use_id = %id, "Removed duplicate tool_use block");
                            continue;
                        }
                        let _ = seen_tool_use_ids.insert(id.clone());
                    }
                    filtered.push(block.clone());
                }

                // Check if remaining content survives API conversion
                if !has_content_surviving_conversion(&filtered) {
                    warn!("Removed assistant message with no content surviving conversion");
                    continue;
                }

                let idx = valid.len();

                // Track tool_use locations for synthetic result injection
                for block in &filtered {
                    if let AssistantContent::ToolUse { id, .. } = block {
                        let _ = tool_use_locations.insert(id.clone(), idx);
                    }
                }

                valid.push(Message::Assistant {
                    content: filtered,
                    usage: None,
                    cost: None,
                    stop_reason: None,
                    thinking: None,
                });
            }
            Message::ToolResult {
                tool_call_id,
                content,
                ..
            } => {
                if tool_call_id.is_empty() {
                    warn!("Removed tool result with empty tool_call_id");
                    continue;
                }
                if !is_valid_tool_result_content(content) {
                    warn!(tool_call_id = %tool_call_id, "Removed empty tool result");
                    continue;
                }
                valid.push(msg);
            }
        }
    }

    // PHASE 2: Collect existing tool result IDs
    let existing_result_ids: HashSet<&str> = valid
        .iter()
        .filter_map(|msg| {
            if let Message::ToolResult { tool_call_id, .. } = msg {
                Some(tool_call_id.as_str())
            } else {
                None
            }
        })
        .collect();

    // PHASE 3: Inject synthetic tool results for unmatched tool_use blocks
    // Group missing IDs by assistant message index
    let mut missing_by_index: HashMap<usize, Vec<String>> = HashMap::new();
    for (tool_use_id, assistant_idx) in &tool_use_locations {
        if !existing_result_ids.contains(tool_use_id.as_str()) {
            missing_by_index
                .entry(*assistant_idx)
                .or_default()
                .push(tool_use_id.clone());
        }
    }

    // Sort indices descending to insert without shifting issues
    let mut sorted_indices: Vec<usize> = missing_by_index.keys().copied().collect();
    sorted_indices.sort_unstable_by(|a, b| b.cmp(a));

    for assistant_idx in sorted_indices {
        if let Some(missing_ids) = missing_by_index.get(&assistant_idx) {
            // Insert in reverse to maintain original tool_use order
            for tool_call_id in missing_ids.iter().rev() {
                warn!(tool_call_id = %tool_call_id, "Injected synthetic tool result for interrupted execution");
                valid.insert(
                    assistant_idx + 1,
                    Message::ToolResult {
                        tool_call_id: tool_call_id.clone(),
                        content: ToolResultMessageContent::Text(INTERRUPTED_CONTENT.into()),
                        is_error: None,
                    },
                );
            }
        }
    }

    // PHASE 4: Ensure first message is user role
    if !valid.is_empty() && !valid[0].is_user() {
        warn!("Injected placeholder user message at start");
        valid.insert(0, Message::user(CONTINUED_CONTENT));
    }

    valid
}

/// Check if assistant content will survive API conversion.
///
/// Thinking blocks without signatures are filtered out before sending to the API.
/// If a message contains ONLY such blocks, it would become empty.
fn has_content_surviving_conversion(content: &[AssistantContent]) -> bool {
    content.iter().any(|block| match block {
        AssistantContent::Text { .. } | AssistantContent::ToolUse { .. } => true,
        AssistantContent::Thinking { signature, .. } => {
            signature.as_ref().is_some_and(|s| !s.is_empty())
        }
    })
}

/// Check if user message content is non-empty.
fn is_valid_user_content(content: &tron_core::messages::UserMessageContent) -> bool {
    match content {
        tron_core::messages::UserMessageContent::Text(text) => !text.trim().is_empty(),
        tron_core::messages::UserMessageContent::Blocks(blocks) => !blocks.is_empty(),
    }
}

/// Check if tool result content is non-empty.
fn is_valid_tool_result_content(content: &ToolResultMessageContent) -> bool {
    match content {
        ToolResultMessageContent::Text(_) => true,
        ToolResultMessageContent::Blocks(blocks) => !blocks.is_empty(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;
    use tron_core::content::AssistantContent;
    use tron_core::messages::{Message, ToolResultMessageContent};

    fn tool_use(id: &str, name: &str) -> AssistantContent {
        AssistantContent::ToolUse {
            id: id.into(),
            name: name.into(),
            arguments: Map::new(),
            thought_signature: None,
        }
    }

    fn tool_result(tool_call_id: &str, text: &str) -> Message {
        Message::ToolResult {
            tool_call_id: tool_call_id.into(),
            content: ToolResultMessageContent::Text(text.into()),
            is_error: None,
        }
    }

    fn assistant_with_content(content: Vec<AssistantContent>) -> Message {
        Message::Assistant {
            content,
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }
    }

    // ── Phase 1: Filter invalid & deduplicate ────────────────────────────

    #[test]
    fn empty_messages_filtered() {
        let messages = vec![
            Message::user("hello"),
            Message::User {
                content: tron_core::messages::UserMessageContent::Text("  ".into()),
                timestamp: None,
            },
            Message::assistant("world"),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
        assert!(result[0].is_user());
        assert!(result[1].is_assistant());
    }

    #[test]
    fn thinking_only_assistant_filtered() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![AssistantContent::Thinking {
                thinking: "display only".into(),
                signature: None,
            }]),
            Message::assistant("visible"),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
        assert!(result[0].is_user());
        assert!(result[1].is_assistant());
    }

    #[test]
    fn thinking_with_signature_preserved() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "deep thought".into(),
                    signature: Some("sig123".into()),
                },
                AssistantContent::text("answer"),
            ]),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn duplicate_tool_use_ids_removed() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                tool_use("tc-1", "bash"),
                AssistantContent::text("some text"),
            ]),
            tool_result("tc-1", "output"),
            // Second assistant reuses the same tool_use ID
            assistant_with_content(vec![
                tool_use("tc-1", "bash"),
                AssistantContent::text("more text"),
            ]),
        ];
        let result = sanitize_messages(messages);
        // The second assistant message should have the duplicate tool_use removed
        // but still keep the text block
        assert_eq!(result.len(), 4);
        if let Message::Assistant { content, .. } = &result[3] {
            assert_eq!(content.len(), 1); // only text remains
            assert!(content[0].is_text());
        } else {
            panic!("Expected assistant message");
        }
    }

    // ── Phase 2-3: Synthetic tool results ────────────────────────────────

    #[test]
    fn unmatched_tool_use_gets_synthetic_result() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![tool_use("tc-1", "bash")]),
            // No tool result for tc-1
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 3);
        assert!(result[0].is_user());
        assert!(result[1].is_assistant());
        // Synthetic result injected
        if let Message::ToolResult {
            tool_call_id,
            content,
            ..
        } = &result[2]
        {
            assert_eq!(tool_call_id, "tc-1");
            if let ToolResultMessageContent::Text(text) = content {
                assert_eq!(text, "[Interrupted]");
            }
        } else {
            panic!("Expected synthetic tool result");
        }
    }

    #[test]
    fn matched_tool_use_no_synthetic_result() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![tool_use("tc-1", "bash")]),
            tool_result("tc-1", "output"),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 3); // No synthetic result needed
    }

    #[test]
    fn multiple_unmatched_tool_uses_all_get_synthetic_results() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                tool_use("tc-1", "bash"),
                tool_use("tc-2", "read"),
                tool_use("tc-3", "write"),
            ]),
        ];
        let result = sanitize_messages(messages);
        // user + assistant + 3 synthetic results
        assert_eq!(result.len(), 5);
        assert!(result[2].is_tool_result());
        assert!(result[3].is_tool_result());
        assert!(result[4].is_tool_result());
    }

    // ── Phase 4: First message must be user ──────────────────────────────

    #[test]
    fn first_message_assistant_gets_user_prepended() {
        let messages = vec![assistant_with_content(vec![AssistantContent::text(
            "response",
        )])];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
        assert!(result[0].is_user());
        if let Message::User {
            content: tron_core::messages::UserMessageContent::Text(text),
            ..
        } = &result[0]
        {
            assert_eq!(text, "[Continued]");
        }
    }

    #[test]
    fn first_message_user_unchanged() {
        let messages = vec![Message::user("hello"), Message::assistant("world")];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
        assert!(result[0].is_user());
    }

    // ── Idempotent ───────────────────────────────────────────────────────

    #[test]
    fn clean_messages_unchanged() {
        let messages = vec![
            Message::user("hello"),
            Message::assistant("world"),
            Message::user("follow-up"),
        ];
        let result = sanitize_messages(messages.clone());
        assert_eq!(result.len(), 3);
    }

    #[test]
    fn idempotent_double_sanitize() {
        let messages = vec![
            assistant_with_content(vec![tool_use("tc-1", "bash")]),
            Message::user("hello"),
        ];
        let first = sanitize_messages(messages);
        let second = sanitize_messages(first.clone());
        assert_eq!(first.len(), second.len());
    }

    // ── Multiple consecutive ToolResults preserved ───────────────────────

    #[test]
    fn multiple_consecutive_tool_results_preserved() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                tool_use("tc-1", "bash"),
                tool_use("tc-2", "read"),
                tool_use("tc-3", "write"),
            ]),
            tool_result("tc-1", "output1"),
            tool_result("tc-2", "output2"),
            tool_result("tc-3", "output3"),
        ];
        let result = sanitize_messages(messages);
        // All messages should be preserved as-is
        assert_eq!(result.len(), 5);
    }

    #[test]
    fn empty_input_returns_empty() {
        let result = sanitize_messages(vec![]);
        assert!(result.is_empty());
    }
}
