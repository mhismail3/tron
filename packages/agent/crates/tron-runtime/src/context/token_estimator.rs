//! Token estimation utilities.
//!
//! Pure functions for estimating token counts from text, messages, tools,
//! and images. Uses a chars/4 approximation consistent with Anthropic's
//! tokenizer.
//!
//! ## Formula
//!
//! - Text content: `tokens ≈ characters / 4`
//! - Images (Anthropic): `tokens = (width × height) / 750`
//!   - Pixels estimated from base64 data size
//!   - Minimum 85 tokens per image
//!   - Default 1500 tokens for URL images (typical 1024×1024)

use serde_json::Value;
use tron_core::content::{AssistantContent, ToolResultContent, UserContent};
use tron_core::messages::{Message, ToolResultMessageContent, UserMessageContent};
use tron_core::tools::Tool;

use super::constants::{CHARS_PER_TOKEN, DEFAULT_URL_IMAGE_TOKENS, MIN_IMAGE_TOKENS, RULES_HEADER};

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
    /// URL-referenced image.
    Url {
        /// Image URL.
        url: String,
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
        Some(ImageSource::Url { .. }) | None => DEFAULT_URL_IMAGE_TOKENS,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Block Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate character count for a content block (internal helper).
///
/// Avoids precision loss from double conversion by working in chars.
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

        "tool_use" => {
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

        "tool_result" => {
            let mut chars = 0usize;
            if let Some(id) = obj.get("tool_use_id").and_then(Value::as_str) {
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

        // Unknown type — fall back to JSON serialization
        _ => block.to_string().len(),
    }
}

/// Estimate tokens for a content block.
///
/// Handles text, thinking, tool\_use, tool\_result, and image blocks.
#[must_use]
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
        AssistantContent::ToolUse {
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

/// Estimate character count for a [`ToolResultContent`] block.
fn estimate_tool_result_content_chars(content: &ToolResultContent) -> usize {
    match content {
        ToolResultContent::Text { text } => text.len(),
        ToolResultContent::Image { data, .. } => {
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
        Message::ToolResult { .. } => "toolResult",
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
        Message::ToolResult {
            tool_call_id,
            content,
            ..
        } => {
            chars += tool_call_id.len();
            match content {
                ToolResultMessageContent::Text(text) => chars += text.len(),
                ToolResultMessageContent::Blocks(blocks) => {
                    for block in blocks {
                        chars += estimate_tool_result_content_chars(block);
                    }
                }
            }
        }
    }

    chars_to_tokens(chars)
}

/// Estimate tokens for an array of messages.
#[must_use]
pub fn estimate_messages_tokens(messages: &[Message]) -> u32 {
    messages.iter().map(estimate_message_tokens).sum()
}

// ─────────────────────────────────────────────────────────────────────────────
// System & Tools Estimation
// ─────────────────────────────────────────────────────────────────────────────

/// Estimate tokens for the system prompt.
///
/// Optionally includes a tool clarification message (for Codex providers).
#[must_use]
pub fn estimate_system_prompt_tokens(system_prompt: &str, tool_clarification: Option<&str>) -> u32 {
    let total_length = system_prompt.len() + tool_clarification.map_or(0, str::len);
    chars_to_tokens(total_length)
}

/// Estimate tokens for tool definitions.
#[must_use]
pub fn estimate_tools_tokens(tools: &[Tool]) -> u32 {
    let total_chars: usize = tools
        .iter()
        .map(|t| serde_json::to_string(t).map_or(0, |s| s.len()))
        .sum();
    chars_to_tokens(total_chars)
}

/// Estimate tokens for rules content.
///
/// Includes header overhead (`"# Project Rules\n\n"`, 18 chars).
#[must_use]
pub fn estimate_rules_tokens(rules_content: Option<&str>) -> u32 {
    match rules_content {
        Some(content) if !content.is_empty() => chars_to_tokens(content.len() + RULES_HEADER.len()),
        _ => 0,
    }
}

/// Estimate tokens for system prompt and tools combined.
#[must_use]
pub fn estimate_system_tokens(system_prompt: &str, tools: &[Tool]) -> u32 {
    let mut chars = system_prompt.len();
    for tool in tools {
        chars += serde_json::to_string(tool).map_or(0, |s| s.len());
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
    fn image_tokens_url_returns_default() {
        let source = ImageSource::Url {
            url: "https://example.com/image.png".to_string(),
        };
        assert_eq!(
            estimate_image_tokens(Some(&source)),
            DEFAULT_URL_IMAGE_TOKENS
        );
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
    fn block_tokens_tool_use() {
        let block = json!({
            "type": "tool_use",
            "id": "toolu_01",
            "name": "read",
            "arguments": {"file_path": "/tmp/test.rs"}
        });
        assert!(estimate_block_tokens(&block) > 0);
    }

    #[test]
    fn block_tokens_tool_use_with_input_field() {
        let block = json!({
            "type": "tool_use",
            "id": "toolu_01",
            "name": "read",
            "input": {"file_path": "/tmp/test.rs"}
        });
        assert!(estimate_block_tokens(&block) > 0);
    }

    #[test]
    fn block_tokens_tool_result() {
        let block = json!({
            "type": "tool_result",
            "tool_use_id": "toolu_01",
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
    fn message_tokens_tool_result() {
        let msg = Message::ToolResult {
            tool_call_id: "toolu_01".into(),
            content: ToolResultMessageContent::Text("result data".into()),
            is_error: None,
        };
        // "toolResult"(10) + 10 + "toolu_01"(8) + "result data"(11) = 39 / 4 = 10
        assert_eq!(estimate_message_tokens(&msg), 10);
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
    fn message_tokens_tool_result_with_blocks() {
        let msg = Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Blocks(vec![
                ToolResultContent::text("line 1"),
                ToolResultContent::text("line 2"),
            ]),
            is_error: None,
        };
        // "toolResult"(10) + 10 + "tc-1"(4) + "line 1"(6) + "line 2"(6) = 36 / 4 = 9
        assert_eq!(estimate_message_tokens(&msg), 9);
    }

    // ── System & tools estimation ────────────────────────────────────────

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
        let clarification = "Use tools wisely.";
        assert_eq!(
            estimate_system_prompt_tokens(prompt, Some(clarification)),
            chars_to_tokens(prompt.len() + clarification.len())
        );
    }

    #[test]
    fn tools_tokens_empty() {
        assert_eq!(estimate_tools_tokens(&[]), 0);
    }

    fn make_test_tool(name: &str, description: &str) -> Tool {
        Tool {
            name: name.to_string(),
            description: description.to_string(),
            parameters: tron_core::tools::ToolParameterSchema {
                schema_type: "object".to_string(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    #[test]
    fn tools_tokens_with_tools() {
        let tools = vec![make_test_tool("read", "Read a file")];
        assert!(estimate_tools_tokens(&tools) > 0);
    }

    #[test]
    fn rules_tokens_none() {
        assert_eq!(estimate_rules_tokens(None), 0);
    }

    #[test]
    fn rules_tokens_empty_string() {
        assert_eq!(estimate_rules_tokens(Some("")), 0);
    }

    #[test]
    fn rules_tokens_with_content() {
        let content = "Follow these rules carefully.";
        // content(29) + header(18) = 47 / 4 = 12
        assert_eq!(estimate_rules_tokens(Some(content)), chars_to_tokens(47));
    }

    #[test]
    fn system_tokens_combined() {
        let prompt = "System prompt here";
        let tools = vec![make_test_tool("bash", "Run commands")];
        let combined = estimate_system_tokens(prompt, &tools);
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
    fn typed_assistant_tool_use_chars() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("cmd".into(), Value::String("ls".into()));
        let block = AssistantContent::ToolUse {
            id: "call_1".into(),
            name: "bash".into(),
            arguments: args,
            thought_signature: None,
        };
        // "call_1"(6) + "bash"(4) + `{"cmd":"ls"}`(12) = 22
        assert_eq!(estimate_assistant_content_chars(&block), 22);
    }

    #[test]
    fn typed_tool_result_text_chars() {
        let block = ToolResultContent::text("output data");
        assert_eq!(estimate_tool_result_content_chars(&block), 11);
    }

    #[test]
    fn typed_tool_result_image_chars() {
        let block = ToolResultContent::Image {
            data: "tiny".into(),
            mime_type: "image/png".into(),
        };
        assert_eq!(
            estimate_tool_result_content_chars(&block),
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
            Message::ToolResult {
                tool_call_id: String::new(),
                content: ToolResultMessageContent::Text(String::new()),
                is_error: None,
            },
        ] {
            assert!(estimate_message_tokens(msg) > 0);
        }
    }

    #[test]
    fn longer_content_means_more_tokens() {
        let short = Message::user("hi");
        let long = Message::user(&"a".repeat(1000));
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
    fn rules_header_length_is_17() {
        // "# Project Rules\n\n" = 15 + 2 newlines = 17
        assert_eq!(RULES_HEADER.len(), 17);
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
    fn ts_parity_tool_result() {
        // chars = 10 + 10 + 4 + 2 = 26, ceil(26/4) = 7
        let msg = Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("ok".into()),
            is_error: None,
        };
        assert_eq!(estimate_message_tokens(&msg), 7);
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

    #[test]
    fn ts_parity_rules_with_header() {
        // total = 10 + 17 = 27, ceil(27/4) = 7
        assert_eq!(estimate_rules_tokens(Some("test rules")), 7);
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
