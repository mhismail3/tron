//! # Message Sanitizer
//!
//! Pre-conversion sanitization for messages before they're sent to the Anthropic API.
//! Ports phases 1–4 from the TypeScript `sanitizeMessages()`.
//!
//! Invariants enforced:
//! 1. Every `capability_invocation` block has a corresponding `ToolResult` message
//! 2. No empty messages
//! 3. No thinking-only assistant messages (display-only, no signature)
//! 4. Signed thinking blocks converted to text (signatures are model-specific)
//! 5. First message is user role
//!
//! This is idempotent: `sanitize(sanitize(x)) == sanitize(x)`.

use std::collections::{HashMap, HashSet};

use tracing::debug;

use crate::shared::content::AssistantContent;
use crate::shared::messages::{CapabilityResultMessageContent, Message};

/// Content for synthetic capability results when execution was interrupted.
const INTERRUPTED_CONTENT: &str = "[Interrupted]";

/// Content for placeholder user message when conversation doesn't start with user.
const CONTINUED_CONTENT: &str = "[Continued]";

/// Sanitize messages to guarantee API compliance.
///
/// Returns a new `Vec<Message>` with fixes applied:
/// - Signed thinking blocks converted to text (cross-model signature normalization)
/// - Empty messages filtered out
/// - Thinking-only assistant messages (unsigned, display-only) filtered out
/// - Duplicate `capability_invocation` IDs deduplicated
/// - Synthetic capability results injected for unmatched `capability_invocation` blocks
/// - Placeholder user message prepended if first message isn't user
pub fn sanitize_messages(messages: Vec<Message>) -> Vec<Message> {
    // PHASE 1: Filter invalid messages, deduplicate capability_invocation IDs
    let mut valid: Vec<Message> = Vec::with_capacity(messages.len());
    let mut seen_capability_invocation_ids: HashSet<String> = HashSet::new();
    // capability_invocation_id → index in `valid` where the assistant message lives
    let mut capability_invocation_locations: HashMap<String, usize> = HashMap::new();

    for msg in messages {
        match &msg {
            Message::User { content, .. } => {
                if !is_valid_user_content(content) {
                    debug!("Removed empty user message");
                    continue;
                }
                valid.push(msg);
            }
            Message::Assistant { content, .. } => {
                // Filter duplicate capability_invocation blocks + convert signed thinking to text.
                // Thinking signatures are model-specific cryptographic tokens — a signature
                // from MiniMax or a different Anthropic model will be rejected by the target.
                // Converting to text preserves reasoning content without the invalid wrapper.
                let mut filtered: Vec<AssistantContent> = Vec::with_capacity(content.len());
                for block in content {
                    match block {
                        AssistantContent::CapabilityInvocation { id, .. } => {
                            if seen_capability_invocation_ids.contains(id) {
                                debug!(capability_invocation_id = %id, "Removed duplicate capability_invocation block");
                                continue;
                            }
                            let _ = seen_capability_invocation_ids.insert(id.clone());
                            filtered.push(block.clone());
                        }
                        AssistantContent::Thinking {
                            thinking,
                            signature: Some(_),
                        } => {
                            debug!(
                                "Converted signed thinking block to text (cross-model signature)"
                            );
                            filtered.push(AssistantContent::text(thinking.clone()));
                        }
                        _ => {
                            filtered.push(block.clone());
                        }
                    }
                }

                // Check if remaining content survives API conversion
                if !has_content_surviving_conversion(&filtered) {
                    debug!("Removed assistant message with no content surviving conversion");
                    continue;
                }

                let idx = valid.len();

                // Track capability_invocation locations for synthetic result injection
                for block in &filtered {
                    if let AssistantContent::CapabilityInvocation { id, .. } = block {
                        let _ = capability_invocation_locations.insert(id.clone(), idx);
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
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                if invocation_id.is_empty() {
                    debug!("Removed capability result with empty invocation_id");
                    continue;
                }
                if !is_valid_capability_result_content(content) {
                    debug!(invocation_id = %invocation_id, "Removed empty capability result");
                    continue;
                }
                valid.push(msg);
            }
        }
    }

    // PHASE 2: Collect existing capability result IDs
    let existing_result_ids: HashSet<&str> = valid
        .iter()
        .filter_map(|msg| {
            if let Message::CapabilityResult { invocation_id, .. } = msg {
                Some(invocation_id.as_str())
            } else {
                None
            }
        })
        .collect();

    // PHASE 3: Inject synthetic capability results for unmatched capability_invocation blocks
    // Group missing IDs by assistant message index
    let mut missing_by_index: HashMap<usize, Vec<String>> = HashMap::new();
    for (capability_invocation_id, assistant_idx) in &capability_invocation_locations {
        if !existing_result_ids.contains(capability_invocation_id.as_str()) {
            missing_by_index
                .entry(*assistant_idx)
                .or_default()
                .push(capability_invocation_id.clone());
        }
    }

    // Sort indices descending to insert without shifting issues
    let mut sorted_indices: Vec<usize> = missing_by_index.keys().copied().collect();
    sorted_indices.sort_unstable_by(|a, b| b.cmp(a));

    for assistant_idx in sorted_indices {
        if let Some(missing_ids) = missing_by_index.get(&assistant_idx) {
            // Insert in reverse to maintain original capability_invocation order
            for invocation_id in missing_ids.iter().rev() {
                debug!(invocation_id = %invocation_id, "Injected synthetic capability result for interrupted execution");
                valid.insert(
                    assistant_idx + 1,
                    Message::CapabilityResult {
                        invocation_id: invocation_id.clone(),
                        content: CapabilityResultMessageContent::Text(INTERRUPTED_CONTENT.into()),
                        is_error: None,
                    },
                );
            }
        }
    }

    // PHASE 4: Ensure first message is user role
    if !valid.is_empty() && !valid[0].is_user() {
        debug!("Injected placeholder user message at start");
        valid.insert(0, Message::user(CONTINUED_CONTENT));
    }

    valid
}

/// Check if assistant content will survive API conversion.
///
/// Called AFTER signed thinking blocks have been converted to text blocks.
/// Only unsigned thinking (`signature: None`) remains at this point, and the
/// converter filters those out. If a message contains ONLY unsigned thinking,
/// it would become empty after conversion.
fn has_content_surviving_conversion(content: &[AssistantContent]) -> bool {
    content.iter().any(|block| {
        !matches!(
            block,
            AssistantContent::Thinking {
                signature: None,
                ..
            }
        )
    })
}

/// Check if user message content is non-empty.
fn is_valid_user_content(content: &crate::shared::messages::UserMessageContent) -> bool {
    match content {
        crate::shared::messages::UserMessageContent::Text(text) => !text.trim().is_empty(),
        crate::shared::messages::UserMessageContent::Blocks(blocks) => !blocks.is_empty(),
    }
}

/// Check if capability result content is non-empty.
fn is_valid_capability_result_content(content: &CapabilityResultMessageContent) -> bool {
    match content {
        CapabilityResultMessageContent::Text(_) => true,
        CapabilityResultMessageContent::Blocks(blocks) => !blocks.is_empty(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::content::AssistantContent;
    use crate::shared::messages::{CapabilityResultMessageContent, Message};
    use serde_json::Map;

    fn capability_invocation(id: &str, name: &str) -> AssistantContent {
        AssistantContent::CapabilityInvocation {
            id: id.into(),
            name: name.into(),
            arguments: Map::new(),
            thought_signature: None,
        }
    }

    fn capability_result(invocation_id: &str, text: &str) -> Message {
        Message::CapabilityResult {
            invocation_id: invocation_id.into(),
            content: CapabilityResultMessageContent::Text(text.into()),
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
                content: crate::shared::messages::UserMessageContent::Text("  ".into()),
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
    fn signed_thinking_converted_to_text_in_mixed_message() {
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
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 2);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "deep thought");
            assert!(content[1].is_text());
            assert_eq!(content[1].as_text().unwrap(), "answer");
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn duplicate_capability_invocation_ids_removed() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                capability_invocation("tc-1", "execute"),
                AssistantContent::text("some text"),
            ]),
            capability_result("tc-1", "output"),
            // Second assistant reuses the same capability_invocation ID
            assistant_with_content(vec![
                capability_invocation("tc-1", "execute"),
                AssistantContent::text("more text"),
            ]),
        ];
        let result = sanitize_messages(messages);
        // The second assistant message should have the duplicate capability_invocation removed
        // but still keep the text block
        assert_eq!(result.len(), 4);
        if let Message::Assistant { content, .. } = &result[3] {
            assert_eq!(content.len(), 1); // only text remains
            assert!(content[0].is_text());
        } else {
            panic!("Expected assistant message");
        }
    }

    // ── Phase 2-3: Synthetic capability results ────────────────────────────────

    #[test]
    fn unmatched_capability_invocation_gets_synthetic_result() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![capability_invocation("tc-1", "execute")]),
            // No capability result for tc-1
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 3);
        assert!(result[0].is_user());
        assert!(result[1].is_assistant());
        // Synthetic result injected
        if let Message::CapabilityResult {
            invocation_id,
            content,
            ..
        } = &result[2]
        {
            assert_eq!(invocation_id, "tc-1");
            if let CapabilityResultMessageContent::Text(text) = content {
                assert_eq!(text, "[Interrupted]");
            }
        } else {
            panic!("Expected synthetic capability result");
        }
    }

    #[test]
    fn matched_capability_invocation_no_synthetic_result() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![capability_invocation("tc-1", "execute")]),
            capability_result("tc-1", "output"),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 3); // No synthetic result needed
    }

    #[test]
    fn multiple_unmatched_capability_invocations_all_get_synthetic_results() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                capability_invocation("tc-1", "execute"),
                capability_invocation("tc-2", "inspect"),
                capability_invocation("tc-3", "search"),
            ]),
        ];
        let result = sanitize_messages(messages);
        // user + assistant + 3 synthetic results
        assert_eq!(result.len(), 5);
        assert!(result[2].is_capability_result());
        assert!(result[3].is_capability_result());
        assert!(result[4].is_capability_result());
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
            content: crate::shared::messages::UserMessageContent::Text(text),
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
            assistant_with_content(vec![capability_invocation("tc-1", "execute")]),
            Message::user("hello"),
        ];
        let first = sanitize_messages(messages);
        let second = sanitize_messages(first.clone());
        assert_eq!(first.len(), second.len());
    }

    // ── Multiple consecutive ToolResults preserved ───────────────────────

    #[test]
    fn multiple_consecutive_capability_results_preserved() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                capability_invocation("tc-1", "execute"),
                capability_invocation("tc-2", "inspect"),
                capability_invocation("tc-3", "search"),
            ]),
            capability_result("tc-1", "output1"),
            capability_result("tc-2", "output2"),
            capability_result("tc-3", "output3"),
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

    // ── Signed thinking → text conversion ───────────────────────────────

    #[test]
    fn cross_provider_signed_thinking_converted_to_text() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "Let me search for that.".into(),
                    signature: Some("d7f2ef852b1a3c4e5f6a7b8c9d0e1f2a3b4c5d6e".into()),
                },
                capability_invocation("call_abc123", "execute"),
            ]),
            capability_result("call_abc123", "output"),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 3);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 2);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "Let me search for that.");
            assert!(matches!(
                content[1],
                AssistantContent::CapabilityInvocation { .. }
            ));
            assert!(!content.iter().any(AssistantContent::is_thinking));
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn thinking_only_with_signature_converted_to_text_preserved() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![AssistantContent::Thinking {
                thinking: "just thinking".into(),
                signature: Some("somesig".into()),
            }]),
        ];
        let result = sanitize_messages(messages);
        assert_eq!(result.len(), 2);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 1);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "just thinking");
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn multiple_signed_thinking_blocks_all_converted() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "first thought".into(),
                    signature: Some("sig1".into()),
                },
                AssistantContent::Thinking {
                    thinking: "second thought".into(),
                    signature: Some("sig2".into()),
                },
                capability_invocation("tc-1", "execute"),
            ]),
            capability_result("tc-1", "output"),
        ];
        let result = sanitize_messages(messages);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 3);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "first thought");
            assert!(content[1].is_text());
            assert_eq!(content[1].as_text().unwrap(), "second thought");
            assert!(matches!(
                content[2],
                AssistantContent::CapabilityInvocation { .. }
            ));
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn mixed_signed_and_unsigned_thinking() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "signed reasoning".into(),
                    signature: Some("sig_abc".into()),
                },
                AssistantContent::Thinking {
                    thinking: "unsigned display-only".into(),
                    signature: None,
                },
                AssistantContent::text("visible answer"),
            ]),
        ];
        let result = sanitize_messages(messages);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 3);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "signed reasoning");
            assert!(content[1].is_thinking());
            assert!(content[2].is_text());
            assert_eq!(content[2].as_text().unwrap(), "visible answer");
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn converted_thinking_text_matches_original() {
        let original_text = "My detailed reasoning about X";
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: original_text.into(),
                    signature: Some("sig".into()),
                },
                AssistantContent::text("answer"),
            ]),
        ];
        let result = sanitize_messages(messages);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content[0].as_text().unwrap(), original_text);
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn empty_signature_converted_to_text() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "empty sig thinking".into(),
                    signature: Some(String::new()),
                },
                AssistantContent::text("answer"),
            ]),
        ];
        let result = sanitize_messages(messages);
        if let Message::Assistant { content, .. } = &result[1] {
            assert_eq!(content.len(), 2);
            assert!(content[0].is_text());
            assert_eq!(content[0].as_text().unwrap(), "empty sig thinking");
        } else {
            panic!("Expected assistant message");
        }
    }

    #[test]
    fn idempotent_with_signed_thinking() {
        let messages = vec![
            Message::user("hello"),
            assistant_with_content(vec![
                AssistantContent::Thinking {
                    thinking: "reasoning".into(),
                    signature: Some("sig_xyz".into()),
                },
                AssistantContent::text("answer"),
            ]),
        ];
        let first = sanitize_messages(messages);
        let second = sanitize_messages(first.clone());
        assert_eq!(first.len(), second.len());
        if let (Message::Assistant { content: c1, .. }, Message::Assistant { content: c2, .. }) =
            (&first[1], &second[1])
        {
            assert_eq!(c1.len(), c2.len());
            for (a, b) in c1.iter().zip(c2.iter()) {
                assert_eq!(a.as_text(), b.as_text());
            }
        }
    }
}
