//! Token estimation utilities.
//!
//! Pure functions for estimating token counts from text, messages, capabilities,
//! and images. Uses a chars/4 approximation as a cheap pre-call heuristic.
//! Provider-reported usage remains the source of truth after a model call.
//!
//! ## Formula
//!
//! - Text content: `tokens ≈ characters / 4`
//! - Images (Anthropic): `tokens = (width × height) / 750`
//!   - Pixels estimated from base64 data size
//!   - Minimum 85 tokens per image
//!   - Default 1500 tokens for URL images (typical 1024×1024)

use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};
use crate::shared::protocol::model_capabilities::ModelCapability;
#[cfg(test)]
use serde_json::Value;

use super::constants::{CHARS_PER_TOKEN, DEFAULT_URL_IMAGE_TOKENS, MIN_IMAGE_TOKENS};

/// Shorthand for chars → tokens conversion.
#[allow(clippy::cast_possible_truncation)]
fn chars_to_tokens(chars: usize) -> u32 {
    chars.div_ceil(CHARS_PER_TOKEN as usize) as u32
}

// ─────────────────────────────────────────────────────────────────────────────
// Image Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Image source for token estimation.
#[derive(Debug, Clone)]
pub enum ImageSource {
    /// Base64-encoded image data.
    Base64 {
        /// Raw base64 string (no data: prefix).
        data: String,
    },
}

/// Estimate tokens for an image.
///
/// For base64 images, estimates dimensions from data size:
/// - Base64 overhead is ~33%, so actual bytes = length × 0.75
/// - Uses compression ratio of 5 for mixed content
/// - Minimum 85 tokens per image
///
/// For URL images, uses a conservative default (1500 tokens for ~1024×1024).
#[must_use]
#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]
pub fn estimate_image_tokens(source: Option<&ImageSource>) -> u32 {
    match source {
        Some(ImageSource::Base64 { data }) => {
            let data_length = data.len() as f64;
            let estimated_bytes = data_length * 0.75;
            let estimated_pixels = estimated_bytes * 5.0;
            let tokens = (estimated_pixels / 750.0).ceil() as u32;
            tokens.max(MIN_IMAGE_TOKENS)
        }
        None => DEFAULT_URL_IMAGE_TOKENS,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Block Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate character count for a content block (internal helper).
///
/// Avoids precision loss from double conversion by working in chars.
#[cfg(test)]
fn estimate_block_chars(block: &Value) -> usize {
    let Some(obj) = block.as_object() else {
        return 0;
    };

    let block_type = obj.get("type").and_then(Value::as_str).unwrap_or("");

    match block_type {
        "text" => obj.get("text").and_then(Value::as_str).map_or(0, str::len),

        "thinking" => obj
            .get("thinking")
            .and_then(Value::as_str)
            .map_or(0, str::len),

        "capability_invocation" => {
            let mut chars = 0usize;
            if let Some(id) = obj.get("id").and_then(Value::as_str) {
                chars += id.len();
            }
            if let Some(name) = obj.get("name").and_then(Value::as_str) {
                chars += name.len();
            }
            let empty_obj = Value::Object(serde_json::Map::new());
            let input = obj.get("arguments").unwrap_or(&empty_obj);
            chars += input.to_string().len();
            chars
        }

        "capability_result" => {
            let mut chars = 0usize;
            if let Some(id) = obj.get("capability_invocation_id").and_then(Value::as_str) {
                chars += id.len();
            }
            if let Some(content) = obj.get("content").and_then(Value::as_str) {
                chars += content.len();
            }
            chars
        }

        "image" => {
            let source = obj.get("source").and_then(|s| {
                let src_type = s.get("type").and_then(Value::as_str)?;
                match src_type {
                    "base64" => {
                        s.get("data")
                            .and_then(Value::as_str)
                            .map(|d| ImageSource::Base64 {
                                data: d.to_string(),
                            })
                    }
                    _ => None,
                }
            });
            let tokens = estimate_image_tokens(source.as_ref());
            (tokens * CHARS_PER_TOKEN) as usize
        }

        // Unknown type: use JSON serialization
        _ => block.to_string().len(),
    }
}

/// Estimate tokens for a content block.
///
/// Handles text, thinking, capability invocation/result, and image blocks.
#[must_use]
#[cfg(test)]
pub fn estimate_block_tokens(block: &Value) -> u32 {
    chars_to_tokens(estimate_block_chars(block))
}

// ─────────────────────────────────────────────────────────────────────────────
// Typed Content Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate character count for a [`UserContent`] block.
fn estimate_user_content_chars(content: &UserContent) -> usize {
    match content {
        UserContent::Text { text } => text.len(),
        UserContent::Image { data, .. } => {
            let source = ImageSource::Base64 { data: data.clone() };
            let tokens = estimate_image_tokens(Some(&source));
            (tokens * CHARS_PER_TOKEN) as usize
        }
        UserContent::Document { data, .. } => data.len(),
    }
}

/// Estimate character count for an [`AssistantContent`] block.
fn estimate_assistant_content_chars(content: &AssistantContent) -> usize {
    match content {
        AssistantContent::Text { text } => text.len(),
        AssistantContent::Thinking { thinking, .. } => thinking.len(),
        AssistantContent::CapabilityInvocation {
            id,
            name,
            arguments,
            ..
        } => {
            let args_str = serde_json::to_string(arguments).unwrap_or_default();
            id.len() + name.len() + args_str.len()
        }
    }
}

/// Estimate character count for a [`CapabilityResultContent`] block.
fn estimate_capability_result_content_chars(content: &CapabilityResultContent) -> usize {
    match content {
        CapabilityResultContent::Text { text } => text.len(),
        CapabilityResultContent::Image { data, .. } => {
            let source = ImageSource::Base64 { data: data.clone() };
            let tokens = estimate_image_tokens(Some(&source));
            (tokens * CHARS_PER_TOKEN) as usize
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Message Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate tokens for a single message.
///
/// Includes overhead for role and message structure (~10 chars).
#[must_use]
pub fn estimate_message_tokens(message: &Message) -> u32 {
    let role_str = match message {
        Message::User { .. } => "user",
        Message::Assistant { .. } => "assistant",
        Message::CapabilityResult { .. } => "capabilityResult",
    };
    let mut chars = role_str.len() + 10;

    match message {
        Message::User { content, .. } => match content {
            UserMessageContent::Text(text) => chars += text.len(),
            UserMessageContent::Blocks(blocks) => {
                for block in blocks {
                    chars += estimate_user_content_chars(block);
                }
            }
        },
        Message::Assistant { content, .. } => {
            for block in content {
                chars += estimate_assistant_content_chars(block);
            }
        }
        Message::CapabilityResult {
            invocation_id,
            content,
            ..
        } => {
            chars += invocation_id.len();
            match content {
                CapabilityResultMessageContent::Text(text) => chars += text.len(),
                CapabilityResultMessageContent::Blocks(blocks) => {
                    for block in blocks {
                        chars += estimate_capability_result_content_chars(block);
                    }
                }
            }
        }
    }

    chars_to_tokens(chars)
}

/// Estimate tokens for an array of messages.
#[must_use]
#[cfg(test)]
pub fn estimate_messages_tokens(messages: &[Message]) -> u32 {
    messages.iter().map(estimate_message_tokens).sum()
}

// ─────────────────────────────────────────────────────────────────────────────
// System & Capability Schema Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate tokens for the system prompt.
///
/// Optionally includes a capability clarification message (for Codex providers).
#[must_use]
pub fn estimate_system_prompt_tokens(
    system_prompt: &str,
    capability_clarification: Option<&str>,
) -> u32 {
    let total_length = system_prompt.len() + capability_clarification.map_or(0, str::len);
    chars_to_tokens(total_length)
}

/// Estimate tokens for model capability definitions.
#[must_use]
pub fn estimate_capabilities_tokens(capabilities: &[ModelCapability]) -> u32 {
    let total_chars: usize = capabilities
        .iter()
        .map(|t| serde_json::to_string(t).map_or(0, |s| s.len()))
        .sum();
    chars_to_tokens(total_chars)
}

/// Estimate tokens for system prompt and capabilities combined.
#[must_use]
#[cfg(test)]
pub fn estimate_system_tokens(system_prompt: &str, capabilities: &[ModelCapability]) -> u32 {
    let mut chars = system_prompt.len();
    for capability in capabilities {
        chars += serde_json::to_string(capability).map_or(0, |s| s.len());
    }
    chars_to_tokens(chars)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // ── Image estimation ─────────────────────────────────────────────────

    #[test]
    fn image_tokens_none_returns_default() {
        assert_eq!(estimate_image_tokens(None), DEFAULT_URL_IMAGE_TOKENS);
    }

    #[test]
    fn image_tokens_base64_estimates_from_data_size() {
        // 1000 chars → raw = ceil(1000 * 0.75 * 5 / 750) = 5, but min=85 applies
        let source = ImageSource::Base64 {
            data: "A".repeat(1000),
        };
        assert_eq!(estimate_image_tokens(Some(&source)), MIN_IMAGE_TOKENS);

        // Large enough to exceed minimum: 100_000 chars → ceil(100000*0.75*5/750) = 500
        let large_source = ImageSource::Base64 {
            data: "A".repeat(100_000),
        };
        let large_tokens = estimate_image_tokens(Some(&large_source));
        assert_eq!(large_tokens, 500);
        assert!(large_tokens > MIN_IMAGE_TOKENS);
    }

    #[test]
    fn image_tokens_base64_minimum_enforced() {
        let source = ImageSource::Base64 {
            data: "AAAA".to_string(),
        };
        assert_eq!(estimate_image_tokens(Some(&source)), MIN_IMAGE_TOKENS);
    }

    // ── Block estimation ─────────────────────────────────────────────────

    #[test]
    fn block_tokens_text() {
        let block = json!({"type": "text", "text": "Hello world!"});
        assert_eq!(estimate_block_tokens(&block), 3); // 12 / 4
    }

    #[test]
    fn block_tokens_thinking() {
        let block = json!({"type": "thinking", "thinking": "Let me think about this..."});
        assert_eq!(estimate_block_tokens(&block), chars_to_tokens(26));
    }

    #[test]
    fn block_tokens_capability_invocation() {
        let block = json!({
            "type": "capability_invocation",
            "id": "toolu_01",
            "name": "inspect",
            "arguments": {"file_path": "/tmp/test.rs"}
        });
        assert!(estimate_block_tokens(&block) > 0);
    }

    #[test]
    fn block_tokens_capability_invocation_with_input_field() {
        let block = json!({
            "type": "capability_invocation",
            "id": "toolu_01",
            "name": "inspect",
            "input": {"file_path": "/tmp/test.rs"}
        });
        assert!(estimate_block_tokens(&block) > 0);
    }

    #[test]
    fn block_tokens_capability_result() {
        let block = json!({
            "type": "capability_result",
            "capability_invocation_id": "toolu_01",
            "content": "File contents here"
        });
        // "toolu_01"(8) + "File contents here"(18) = 26 / 4 = 7
        assert_eq!(estimate_block_tokens(&block), 7);
    }

    #[test]
    fn block_tokens_unknown_type() {
        let block = json!({"type": "custom", "data": "something"});
        assert!(estimate_block_tokens(&block) > 0);
    }

    #[test]
    fn block_tokens_non_object() {
        assert_eq!(estimate_block_tokens(&json!("just a string")), 0);
    }

    #[test]
    fn block_tokens_null() {
        assert_eq!(estimate_block_tokens(&Value::Null), 0);
    }

    // ── Message estimation ───────────────────────────────────────────────

    #[test]
    fn message_tokens_user_text() {
        let msg = Message::user("Hello, how are you?");
        // "user"(4) + 10 + "Hello, how are you?"(19) = 33 / 4 = 9
        assert_eq!(estimate_message_tokens(&msg), 9);
    }

    #[test]
    fn message_tokens_assistant_with_blocks() {
        let msg = Message::assistant("Hi there!");
        // "assistant"(9) + 10 + "Hi there!"(9) = 28 / 4 = 7
        assert_eq!(estimate_message_tokens(&msg), 7);
    }

    #[test]
    fn message_tokens_capability_result() {
        let msg = Message::CapabilityResult {
            invocation_id: "toolu_01".into(),
            content: CapabilityResultMessageContent::Text("result data".into()),
            is_error: None,
        };
        // "capabilityResult"(16) + 10 + "toolu_01"(8) + "result data"(11) = 45 / 4 = 12
        assert_eq!(estimate_message_tokens(&msg), 12);
    }

    #[test]
    fn messages_tokens_empty() {
        assert_eq!(estimate_messages_tokens(&[]), 0);
    }

    #[test]
    fn messages_tokens_multiple() {
        let messages = vec![Message::user("Hello"), Message::assistant("Hi!")];
        let total = estimate_messages_tokens(&messages);
        let individual_sum: u32 = messages.iter().map(estimate_message_tokens).sum();
        assert_eq!(total, individual_sum);
    }

    #[test]
    fn message_tokens_user_with_blocks() {
        let msg = Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::text("first part"),
                UserContent::text("second part"),
            ]),
            timestamp: None,
        };
        // "user"(4) + 10 + "first part"(10) + "second part"(11) = 35 / 4 = 9
        assert_eq!(estimate_message_tokens(&msg), 9);
    }

    #[test]
    fn message_tokens_capability_result_with_blocks() {
        let msg = Message::CapabilityResult {
            invocation_id: "tc-1".into(),
            content: CapabilityResultMessageContent::Blocks(vec![
                CapabilityResultContent::text("line 1"),
                CapabilityResultContent::text("line 2"),
            ]),
            is_error: None,
        };
        // "capabilityResult"(16) + 10 + "tc-1"(4) + "line 1"(6) + "line 2"(6) = 42 / 4 = 11
        assert_eq!(estimate_message_tokens(&msg), 11);
    }

    // ── System & capabilities estimation ────────────────────────────────────────

    #[test]
    fn system_prompt_tokens_basic() {
        let prompt = "You are a helpful assistant.";
        assert_eq!(
            estimate_system_prompt_tokens(prompt, None),
            chars_to_tokens(prompt.len())
        );
    }

    #[test]
    fn system_prompt_tokens_with_clarification() {
        let prompt = "You are a helpful assistant.";
        let clarification = "Use capabilities wisely.";
        assert_eq!(
            estimate_system_prompt_tokens(prompt, Some(clarification)),
            chars_to_tokens(prompt.len() + clarification.len())
        );
    }

    #[test]
    fn capabilities_tokens_empty() {
        assert_eq!(estimate_capabilities_tokens(&[]), 0);
    }

    fn make_test_capability(name: &str, description: &str) -> ModelCapability {
        ModelCapability {
            name: name.to_string(),
            description: description.to_string(),
            parameters: crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                schema_type: "object".to_string(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    #[test]
    fn capabilities_tokens_with_capabilities() {
        let capabilities = vec![make_test_capability("inspect", "Read a file")];
        assert!(estimate_capabilities_tokens(&capabilities) > 0);
    }

    #[test]
    fn system_tokens_combined() {
        let prompt = "System prompt here";
        let capabilities = vec![make_test_capability("execute", "Run commands")];
        let combined = estimate_system_tokens(prompt, &capabilities);
        assert!(combined > 0);
        assert!(combined >= estimate_system_prompt_tokens(prompt, None));
    }

    // ── Typed content estimation ────────────────────────────────────────

    #[test]
    fn typed_user_text_chars() {
        let block = UserContent::text("hello world");
        assert_eq!(estimate_user_content_chars(&block), 11);
    }

    #[test]
    fn typed_user_image_chars() {
        let block = UserContent::Image {
            data: "small".into(),
            mime_type: "image/png".into(),
        };
        // Min 85 tokens → 85 * 4 = 340 chars
        assert_eq!(
            estimate_user_content_chars(&block),
            (MIN_IMAGE_TOKENS * CHARS_PER_TOKEN) as usize
        );
    }

    #[test]
    fn typed_user_document_chars() {
        let block = UserContent::Document {
            data: "a".repeat(100),
            mime_type: "application/pdf".into(),
            file_name: None,
            extracted_text: None,
        };
        assert_eq!(estimate_user_content_chars(&block), 100);
    }

    #[test]
    fn typed_assistant_text_chars() {
        assert_eq!(
            estimate_assistant_content_chars(&AssistantContent::text("hello")),
            5
        );
    }

    #[test]
    fn typed_assistant_thinking_chars() {
        let block = AssistantContent::Thinking {
            thinking: "a".repeat(40),
            signature: None,
        };
        assert_eq!(estimate_assistant_content_chars(&block), 40);
    }

    #[test]
    fn typed_assistant_capability_invocation_chars() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("cmd".into(), Value::String("ls".into()));
        let block = AssistantContent::CapabilityInvocation {
            id: "call_1".into(),
            name: "execute".into(),
            arguments: args,
            thought_signature: None,
        };
        // "call_1"(6) + "execute"(7) + `{"cmd":"ls"}`(12) = 25
        assert_eq!(estimate_assistant_content_chars(&block), 25);
    }

    #[test]
    fn typed_capability_result_text_chars() {
        let block = CapabilityResultContent::text("output data");
        assert_eq!(estimate_capability_result_content_chars(&block), 11);
    }

    #[test]
    fn typed_capability_result_image_chars() {
        let block = CapabilityResultContent::Image {
            data: "tiny".into(),
            mime_type: "image/png".into(),
        };
        assert_eq!(
            estimate_capability_result_content_chars(&block),
            (MIN_IMAGE_TOKENS * CHARS_PER_TOKEN) as usize
        );
    }

    // ── Edge cases ──────────────────────────────────────────────────────

    #[test]
    fn empty_message_still_has_overhead() {
        let msg = Message::user("");
        // "user"(4) + 10 = 14, ceil(14/4) = 4
        assert_eq!(estimate_message_tokens(&msg), 4);
    }

    #[test]
    fn message_tokens_always_positive() {
        for msg in &[
            Message::user(""),
            Message::assistant(""),
            Message::CapabilityResult {
                invocation_id: String::new(),
                content: CapabilityResultMessageContent::Text(String::new()),
                is_error: None,
            },
        ] {
            assert!(estimate_message_tokens(msg) > 0);
        }
    }

    #[test]
    fn longer_content_means_more_tokens() {
        let short = Message::user("hi");
        let long = Message::user("a".repeat(1000));
        assert!(estimate_message_tokens(&long) > estimate_message_tokens(&short));
    }

    #[test]
    fn system_prompt_tokens_empty() {
        assert_eq!(estimate_system_prompt_tokens("", None), 0);
    }

    #[test]
    fn system_prompt_tokens_rounds_up() {
        assert_eq!(estimate_system_prompt_tokens("abc", None), 1);
    }

    #[test]
    fn image_tokens_base64_empty_data() {
        let source = ImageSource::Base64 {
            data: String::new(),
        };
        assert_eq!(estimate_image_tokens(Some(&source)), MIN_IMAGE_TOKENS);
    }

    // ── TypeScript parity ────────────────────────────────────────────────

    #[test]
    fn ts_parity_user_message() {
        // TS: estimateMessageTokens({role: 'user', content: 'hello world'})
        // chars = 4 + 10 + 11 = 25, ceil(25/4) = 7
        assert_eq!(estimate_message_tokens(&Message::user("hello world")), 7);
    }

    #[test]
    fn ts_parity_capability_result() {
        // chars = 16 + 10 + 4 + 2 = 32, ceil(32/4) = 8
        let msg = Message::CapabilityResult {
            invocation_id: "tc-1".into(),
            content: CapabilityResultMessageContent::Text("ok".into()),
            is_error: None,
        };
        assert_eq!(estimate_message_tokens(&msg), 8);
    }

    #[test]
    fn ts_parity_image_base64_10k() {
        // bytes = 10000*0.75 = 7500, pixels = 37500, ceil(37500/750) = 50
        // But 50 < MIN_IMAGE_TOKENS(85), so min wins
        let source = ImageSource::Base64 {
            data: "a".repeat(10_000),
        };
        assert_eq!(estimate_image_tokens(Some(&source)), MIN_IMAGE_TOKENS);
    }

    #[test]
    fn ts_parity_image_base64_100k() {
        // 100k chars → bytes = 75000, pixels = 375000, ceil(375000/750) = 500
        let source = ImageSource::Base64 {
            data: "a".repeat(100_000),
        };
        assert_eq!(estimate_image_tokens(Some(&source)), 500);
    }

    // ── chars_to_tokens helper ───────────────────────────────────────────

    #[test]
    fn chars_to_tokens_exact() {
        assert_eq!(chars_to_tokens(8), 2);
        assert_eq!(chars_to_tokens(100), 25);
    }

    #[test]
    fn chars_to_tokens_rounds_up() {
        assert_eq!(chars_to_tokens(9), 3);
        assert_eq!(chars_to_tokens(1), 1);
        assert_eq!(chars_to_tokens(5), 2);
    }

    #[test]
    fn chars_to_tokens_zero() {
        assert_eq!(chars_to_tokens(0), 0);
    }
}
