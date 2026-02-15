use serde_json::{json, Value};

use tron_core::context::{LlmContext, Stability, SystemBlock};
use tron_core::messages::{
    AssistantContent, AssistantMessage, Message, ToolCallBlock, ToolResultContent,
    ToolResultMessage, UserContent, UserMessage,
};
use tron_core::provider::{StreamOptions, ThinkingConfig};

/// Convert a full LlmContext into the Anthropic API request body.
pub fn build_request_body(
    context: &LlmContext,
    options: &StreamOptions,
    model: &str,
    is_oauth: bool,
) -> Value {
    let mut body = json!({
        "model": model,
        "stream": true,
    });

    // Max tokens
    if let Some(max) = options.max_tokens {
        body["max_tokens"] = json!(max);
    } else {
        body["max_tokens"] = json!(128_000);
    }

    // Temperature
    if let Some(temp) = options.temperature {
        body["temperature"] = json!(temp);
    }

    // Stop sequences
    if !options.stop_sequences.is_empty() {
        body["stop_sequences"] = json!(options.stop_sequences);
    }

    // Thinking config
    match &options.thinking {
        ThinkingConfig::Disabled => {}
        ThinkingConfig::Adaptive => {
            body["thinking"] = json!({"type": "enabled", "budget_tokens": 10000});
        }
        ThinkingConfig::Budget { tokens } => {
            body["thinking"] = json!({"type": "enabled", "budget_tokens": tokens});
        }
    }

    // System blocks
    let system_blocks = convert_system_blocks(&context.system_blocks, is_oauth);
    if !system_blocks.is_empty() {
        body["system"] = json!(system_blocks);
    }

    // Messages
    body["messages"] = json!(convert_messages(&context.messages));

    // Tools
    if !context.tools.is_empty() {
        let tools: Vec<Value> = context.tools.iter().map(|t| {
            json!({
                "name": t.name,
                "description": t.description,
                "input_schema": t.parameters_schema,
            })
        }).collect();

        // Add cache_control to last tool (breakpoint 1)
        let mut tools_val = json!(tools);
        if is_oauth {
            if let Some(last) = tools_val.as_array_mut().and_then(|a| a.last_mut()) {
                last["cache_control"] = json!({"type": "ephemeral", "ttl": "1h"});
            }
        }
        body["tools"] = tools_val;
    }

    body
}

/// Convert system blocks to Anthropic's system format with cache breakpoints.
fn convert_system_blocks(blocks: &[SystemBlock], is_oauth: bool) -> Vec<Value> {
    if blocks.is_empty() {
        return vec![];
    }

    let mut result: Vec<Value> = Vec::new();

    // Find the boundary between stable and volatile for cache breakpoints
    let last_stable_idx = blocks.iter().rposition(|b| b.stability == Stability::Stable);
    let last_volatile_idx = blocks.iter().rposition(|b| b.stability == Stability::Volatile);

    for (i, block) in blocks.iter().enumerate() {
        let mut entry = json!({
            "type": "text",
            "text": block.content,
        });

        if is_oauth {
            // Breakpoint 2: last stable system block → 1h cache
            if Some(i) == last_stable_idx {
                entry["cache_control"] = json!({"type": "ephemeral", "ttl": "1h"});
            }
            // Breakpoint 3: last volatile system block → 5m default
            else if Some(i) == last_volatile_idx {
                entry["cache_control"] = json!({"type": "ephemeral"});
            }
        }

        result.push(entry);
    }

    result
}

/// Convert Tron messages to Anthropic API format.
fn convert_messages(messages: &[Message]) -> Vec<Value> {
    let mut result = Vec::new();

    for msg in messages {
        match msg {
            Message::User(user) => {
                result.push(convert_user_message(user));
            }
            Message::Assistant(asst) => {
                result.push(convert_assistant_message(asst));
            }
            Message::ToolResult(tr) => {
                result.push(convert_tool_result(tr));
            }
        }
    }

    // Anthropic requires alternating user/assistant. Add cache breakpoint to last user message.
    // Breakpoint 4: last user message content block → 5m default
    if let Some(last_user_idx) = result.iter().rposition(|m| m["role"] == "user") {
        if let Some(content) = result[last_user_idx]["content"].as_array_mut() {
            if let Some(last_block) = content.last_mut() {
                last_block["cache_control"] = json!({"type": "ephemeral"});
            }
        }
    }

    result
}

fn convert_user_message(msg: &UserMessage) -> Value {
    let content: Vec<Value> = msg
        .content
        .iter()
        .map(|c| match c {
            UserContent::Text { text } => json!({"type": "text", "text": text}),
            UserContent::Image { mime_type, data } => json!({
                "type": "image",
                "source": {"type": "base64", "media_type": mime_type, "data": data}
            }),
            UserContent::Document { mime_type, data } => json!({
                "type": "document",
                "source": {"type": "base64", "media_type": mime_type, "data": data}
            }),
        })
        .collect();

    json!({"role": "user", "content": content})
}

fn convert_assistant_message(msg: &AssistantMessage) -> Value {
    let content: Vec<Value> = msg
        .content
        .iter()
        .filter_map(|c| match c {
            AssistantContent::Text { text } => Some(json!({"type": "text", "text": text})),
            AssistantContent::Thinking { text, signature } => {
                // Only include thinking blocks that have a signature
                signature.as_ref().map(|sig| json!({
                    "type": "thinking",
                    "thinking": text,
                    "signature": sig,
                }))
            }
            AssistantContent::ToolCall(tc) => Some(convert_tool_call(tc)),
        })
        .collect();

    json!({"role": "assistant", "content": content})
}

fn convert_tool_call(tc: &ToolCallBlock) -> Value {
    json!({
        "type": "tool_use",
        "id": remap_tool_call_id(tc.id.as_str()),
        "name": tc.name,
        "input": tc.arguments,
    })
}

fn convert_tool_result(msg: &ToolResultMessage) -> Value {
    let content: Vec<Value> = msg
        .content
        .iter()
        .map(|c| match c {
            ToolResultContent::Text { text } => json!({"type": "text", "text": text}),
            ToolResultContent::Image { mime_type, data } => json!({
                "type": "image",
                "source": {"type": "base64", "media_type": mime_type, "data": data}
            }),
        })
        .collect();

    json!({
        "role": "user",
        "content": [{
            "type": "tool_result",
            "tool_use_id": remap_tool_call_id(msg.tool_call_id.as_str()),
            "content": content,
        }]
    })
}

/// Remap tool call IDs from OpenAI format (call_*) to Anthropic format (toolu_remap_*).
/// If already in Anthropic format (toolu_*), pass through unchanged.
fn remap_tool_call_id(id: &str) -> String {
    if let Some(suffix) = id.strip_prefix("call_") {
        format!("toolu_remap_{suffix}")
    } else {
        id.to_string()
    }
}

/// Reverse remap: Anthropic format back to original.
pub fn unremap_tool_call_id(id: &str) -> String {
    if let Some(suffix) = id.strip_prefix("toolu_remap_") {
        format!("call_{suffix}")
    } else {
        id.to_string()
    }
}

/// Prune old tool results for cache-cold efficiency.
/// Results > max_size chars from turns older than preserve_recent are truncated.
pub fn prune_for_cache_cold(
    messages: &mut [Value],
    max_result_size: usize,
    preserve_recent_turns: usize,
) {
    if messages.len() <= preserve_recent_turns * 2 {
        return;
    }

    let cutoff = messages.len() - (preserve_recent_turns * 2);
    for msg in &mut messages[..cutoff] {
        if let Some(content) = msg.get_mut("content").and_then(|c| c.as_array_mut()) {
            for block in content.iter_mut() {
                if block.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                    if let Some(inner) = block.get_mut("content").and_then(|c| c.as_array_mut()) {
                        for item in inner.iter_mut() {
                            if let Some(text) = item.get("text").and_then(|t| t.as_str()) {
                                if text.len() > max_result_size {
                                    item["text"] = json!(format!(
                                        "[pruned {} chars for cache efficiency]",
                                        text.len()
                                    ));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::context::{LlmContext, SystemBlock, SystemBlockLabel, Stability};
    use tron_core::ids::ToolCallId;
    use tron_core::messages::{
        AssistantContent, AssistantMessage, Message, ToolCallBlock, ToolResultContent,
        ToolResultMessage, UserMessage,
    };

    #[test]
    fn user_text_converts() {
        let msg = UserMessage::text("hello");
        let val = convert_user_message(&msg);
        assert_eq!(val["role"], "user");
        assert_eq!(val["content"][0]["type"], "text");
        assert_eq!(val["content"][0]["text"], "hello");
    }

    #[test]
    fn assistant_text_converts() {
        let msg = AssistantMessage::text("world");
        let val = convert_assistant_message(&msg);
        assert_eq!(val["role"], "assistant");
        assert_eq!(val["content"][0]["type"], "text");
    }

    #[test]
    fn thinking_without_signature_filtered() {
        let msg = AssistantMessage {
            content: vec![
                AssistantContent::Thinking {
                    text: "private thought".into(),
                    signature: None, // No signature → filtered out
                },
                AssistantContent::Text { text: "visible".into() },
            ],
            usage: None,
            stop_reason: None,
        };
        let val = convert_assistant_message(&msg);
        let content = val["content"].as_array().unwrap();
        assert_eq!(content.len(), 1); // Only the text block
        assert_eq!(content[0]["type"], "text");
    }

    #[test]
    fn thinking_with_signature_included() {
        let msg = AssistantMessage {
            content: vec![AssistantContent::Thinking {
                text: "deep thought".into(),
                signature: Some("sig_abc".into()),
            }],
            usage: None,
            stop_reason: None,
        };
        let val = convert_assistant_message(&msg);
        let content = val["content"].as_array().unwrap();
        assert_eq!(content.len(), 1);
        assert_eq!(content[0]["type"], "thinking");
        assert_eq!(content[0]["signature"], "sig_abc");
    }

    #[test]
    fn tool_call_id_remapping() {
        assert_eq!(remap_tool_call_id("call_abc123"), "toolu_remap_abc123");
        assert_eq!(remap_tool_call_id("toolu_existing"), "toolu_existing");

        assert_eq!(unremap_tool_call_id("toolu_remap_abc123"), "call_abc123");
        assert_eq!(unremap_tool_call_id("toolu_existing"), "toolu_existing");
    }

    #[test]
    fn tool_call_converts() {
        let tc = ToolCallBlock {
            id: ToolCallId::from_raw("toolu_123"),
            name: "Read".into(),
            arguments: json!({"file_path": "/tmp/test"}),
            thought_signature: None,
        };
        let val = convert_tool_call(&tc);
        assert_eq!(val["type"], "tool_use");
        assert_eq!(val["id"], "toolu_123");
        assert_eq!(val["name"], "Read");
        assert_eq!(val["input"]["file_path"], "/tmp/test");
    }

    #[test]
    fn tool_result_converts() {
        let msg = ToolResultMessage {
            tool_call_id: ToolCallId::from_raw("toolu_456"),
            content: vec![ToolResultContent::Text { text: "file contents".into() }],
        };
        let val = convert_tool_result(&msg);
        assert_eq!(val["role"], "user");
        assert_eq!(val["content"][0]["type"], "tool_result");
        assert_eq!(val["content"][0]["tool_use_id"], "toolu_456");
    }

    #[test]
    fn system_blocks_with_cache_breakpoints() {
        let blocks = vec![
            SystemBlock {
                content: "You are Claude Code.".into(),
                stability: Stability::Stable,
                label: SystemBlockLabel::CorePrompt,
            },
            SystemBlock {
                content: "Rules here.".into(),
                stability: Stability::Stable,
                label: SystemBlockLabel::StaticRules,
            },
            SystemBlock {
                content: "Skills here.".into(),
                stability: Stability::Volatile,
                label: SystemBlockLabel::SkillContext,
            },
        ];

        let result = convert_system_blocks(&blocks, true);
        assert_eq!(result.len(), 3);

        // Last stable (index 1) should have 1h cache
        assert_eq!(result[1]["cache_control"]["ttl"], "1h");

        // Last volatile (index 2) should have default ephemeral
        assert!(result[2]["cache_control"]["type"].as_str().is_some());
        assert!(result[2]["cache_control"].get("ttl").is_none());

        // First stable should NOT have cache_control
        assert!(result[0].get("cache_control").is_none());
    }

    #[test]
    fn system_blocks_no_cache_without_oauth() {
        let blocks = vec![SystemBlock {
            content: "prompt".into(),
            stability: Stability::Stable,
            label: SystemBlockLabel::CorePrompt,
        }];
        let result = convert_system_blocks(&blocks, false);
        assert!(result[0].get("cache_control").is_none());
    }

    #[test]
    fn full_request_body() {
        let context = LlmContext {
            messages: vec![
                Message::user_text("hello"),
                Message::assistant_text("hi"),
            ],
            system_blocks: vec![SystemBlock {
                content: "system".into(),
                stability: Stability::Stable,
                label: SystemBlockLabel::CorePrompt,
            }],
            tools: vec![],
            working_directory: "/tmp".into(),
        };

        let body = build_request_body(
            &context,
            &StreamOptions::default(),
            "claude-sonnet-4-5-20250929",
            false,
        );

        assert_eq!(body["model"], "claude-sonnet-4-5-20250929");
        assert!(body["stream"].as_bool().unwrap());
        assert_eq!(body["messages"].as_array().unwrap().len(), 2);
        assert_eq!(body["system"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn prune_for_cache_cold_truncates_old() {
        let mut messages = vec![
            // Old turn with large tool result
            json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "x".repeat(5000)}]}]}),
            json!({"role": "assistant", "content": [{"type": "text", "text": "ok"}]}),
            // Recent turns (preserved)
            json!({"role": "user", "content": [{"type": "text", "text": "q1"}]}),
            json!({"role": "assistant", "content": [{"type": "text", "text": "a1"}]}),
            json!({"role": "user", "content": [{"type": "text", "text": "q2"}]}),
            json!({"role": "assistant", "content": [{"type": "text", "text": "a2"}]}),
        ];

        prune_for_cache_cold(&mut messages, 2048, 2);

        // Old tool result should be pruned
        let old_text = messages[0]["content"][0]["content"][0]["text"].as_str().unwrap();
        assert!(old_text.starts_with("[pruned"));

        // Recent turns untouched
        assert_eq!(messages[2]["content"][0]["text"], "q1");
    }
}
