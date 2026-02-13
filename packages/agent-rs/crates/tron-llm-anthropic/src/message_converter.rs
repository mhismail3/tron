//! # Message Converter
//!
//! Converts tron-core [`Context`] messages into Anthropic Messages API format.
//! Handles:
//! - User/assistant/tool-result message conversion
//! - Thinking block signature handling (only include with signature)
//! - Tool call ID remapping for cross-provider compatibility
//! - System prompt construction with OAuth cache breakpoints
//! - Tool definitions with cache control

use std::collections::HashMap;

use serde_json::{json, Value};
use tron_core::content::{AssistantContent, ToolResultContent, UserContent};
use tron_core::messages::{
    Context, Message, ToolResultMessageContent, UserMessageContent,
};
use tron_llm::{
    build_tool_call_id_mapping, compose_context_parts, compose_context_parts_grouped,
    remap_tool_call_id, IdFormat,
};

use crate::types::{
    AnthropicMessageParam, AnthropicTool, CacheControl, SystemPromptBlock,
    OAUTH_SYSTEM_PROMPT_PREFIX,
};

// ─────────────────────────────────────────────────────────────────────────────
// Message conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a [`Context`] into Anthropic Messages API parameters.
///
/// Returns `(system, messages, tools)` where:
/// - `system` is the system prompt (string for API key, array of blocks for OAuth)
/// - `messages` is the list of Anthropic message params
/// - `tools` is the optional tool list
pub fn convert_context(
    context: &Context,
    is_oauth: bool,
) -> (Option<Value>, Vec<AnthropicMessageParam>, Option<Vec<AnthropicTool>>) {
    // Build tool call ID mapping for cross-provider compatibility
    let id_mapping = build_id_mapping(&context.messages);

    // Convert messages
    let messages = convert_messages_impl(&context.messages, &id_mapping);

    // Convert tools
    let tools = context.tools.as_ref().map(|t| convert_tools(t, is_oauth));

    // Build system prompt
    let system = build_system_prompt(context, is_oauth);

    (system, messages, tools)
}

/// Build tool call ID mapping from messages for cross-provider compatibility.
fn build_id_mapping(messages: &[Message]) -> HashMap<String, String> {
    let mut all_tool_calls = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for c in content {
                if let AssistantContent::ToolUse { id, .. } = c {
                    all_tool_calls.push(id.as_str());
                }
            }
        }
    }
    build_tool_call_id_mapping(&all_tool_calls, IdFormat::Anthropic)
}

/// Convert conversation messages to Anthropic format.
///
/// Builds tool call ID remapping internally, converting OpenAI-format
/// IDs to Anthropic format (`toolu_remap_N`).
pub fn convert_messages(messages: &[Message]) -> Vec<AnthropicMessageParam> {
    let id_mapping = build_id_mapping(messages);
    convert_messages_impl(messages, &id_mapping)
}

/// Convert conversation messages to Anthropic format with an explicit ID mapping.
fn convert_messages_impl(
    messages: &[Message],
    id_mapping: &HashMap<String, String>,
) -> Vec<AnthropicMessageParam> {
    let mut result = Vec::new();

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                result.push(convert_user_message(content));
            }
            Message::Assistant { content, .. } => {
                result.push(convert_assistant_message(content, id_mapping));
            }
            Message::ToolResult {
                tool_call_id,
                content,
                is_error,
            } => {
                result.push(convert_tool_result(
                    tool_call_id,
                    content,
                    *is_error,
                    id_mapping,
                ));
            }
        }
    }

    result
}

/// Convert a user message to Anthropic format.
fn convert_user_message(content: &UserMessageContent) -> AnthropicMessageParam {
    let blocks = match content {
        UserMessageContent::Text(text) => {
            vec![json!({"type": "text", "text": text})]
        }
        UserMessageContent::Blocks(blocks) => blocks.iter().map(convert_user_content).collect(),
    };

    AnthropicMessageParam {
        role: "user".into(),
        content: blocks,
    }
}

/// Convert a user content block to Anthropic JSON format.
fn convert_user_content(content: &UserContent) -> Value {
    match content {
        UserContent::Text { text } => json!({"type": "text", "text": text}),
        UserContent::Image { data, mime_type } => json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": mime_type,
                "data": data,
            }
        }),
        UserContent::Document { data, mime_type, .. } => json!({
            "type": "document",
            "source": {
                "type": "base64",
                "media_type": mime_type,
                "data": data,
            }
        }),
    }
}

/// Convert an assistant message to Anthropic format.
///
/// Thinking blocks are only included if they have a signature (extended thinking).
/// Display-only thinking (no signature) is filtered out — sending it back to the
/// API would cause a validation error.
fn convert_assistant_message(
    content: &[AssistantContent],
    id_mapping: &HashMap<String, String>,
) -> AnthropicMessageParam {
    let blocks: Vec<Value> = content
        .iter()
        .filter_map(|c| convert_assistant_content(c, id_mapping))
        .collect();

    AnthropicMessageParam {
        role: "assistant".into(),
        content: blocks,
    }
}

/// Convert a single assistant content block to Anthropic JSON.
///
/// Returns `None` for thinking blocks without a signature (display-only).
fn convert_assistant_content(
    content: &AssistantContent,
    id_mapping: &HashMap<String, String>,
) -> Option<Value> {
    match content {
        AssistantContent::Text { text } => Some(json!({"type": "text", "text": text})),
        AssistantContent::Thinking {
            thinking,
            signature,
        } => {
            // Only include thinking blocks with signatures (extended thinking models).
            // Display-only thinking (no signature) MUST NOT be sent back.
            let sig = signature.as_ref()?;
            Some(json!({
                "type": "thinking",
                "thinking": thinking,
                "signature": sig,
            }))
        }
        AssistantContent::ToolUse {
            id,
            name,
            arguments,
            ..
        } => {
            let remapped_id = remap_tool_call_id(id, id_mapping);
            Some(json!({
                "type": "tool_use",
                "id": remapped_id,
                "name": name,
                "input": arguments,
            }))
        }
    }
}

/// Convert a tool result message to Anthropic format.
fn convert_tool_result(
    tool_call_id: &str,
    content: &ToolResultMessageContent,
    is_error: Option<bool>,
    id_mapping: &HashMap<String, String>,
) -> AnthropicMessageParam {
    let remapped_id = remap_tool_call_id(tool_call_id, id_mapping);

    let result_content = match content {
        ToolResultMessageContent::Text(text) => vec![json!({"type": "text", "text": text})],
        ToolResultMessageContent::Blocks(blocks) => {
            blocks.iter().map(convert_tool_result_content).collect()
        }
    };

    let mut block = json!({
        "type": "tool_result",
        "tool_use_id": remapped_id,
        "content": result_content,
    });

    if is_error == Some(true) {
        block["is_error"] = json!(true);
    }

    AnthropicMessageParam {
        role: "user".into(),
        content: vec![block],
    }
}

/// Convert a tool result content block to Anthropic JSON.
fn convert_tool_result_content(content: &ToolResultContent) -> Value {
    match content {
        ToolResultContent::Text { text } => json!({"type": "text", "text": text}),
        ToolResultContent::Image { data, mime_type } => json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": mime_type,
                "data": data,
            }
        }),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// System prompt
// ─────────────────────────────────────────────────────────────────────────────

/// Build the system prompt value.
///
/// For OAuth: returns an array of [`SystemPromptBlock`]s with cache breakpoints.
/// For API key: returns a plain concatenated string.
fn build_system_prompt(context: &Context, is_oauth: bool) -> Option<Value> {
    if is_oauth {
        Some(build_system_prompt_oauth(context))
    } else {
        build_system_prompt_plain(context)
    }
}

/// Build system prompt for OAuth connections with cache breakpoints.
///
/// Cache breakpoints (4-tier):
/// - Breakpoint 2: Last stable block (rules, system prompt) → 1h TTL
/// - Breakpoint 3: Last volatile block (memory) → 5m TTL (default)
fn build_system_prompt_oauth(context: &Context) -> Value {
    let grouped = compose_context_parts_grouped(context);

    let mut blocks: Vec<SystemPromptBlock> = Vec::new();

    // OAuth prefix (always first)
    blocks.push(SystemPromptBlock::text(OAUTH_SYSTEM_PROMPT_PREFIX));

    // Stable parts (system prompt, rules — cache at 1h)
    for part in &grouped.stable {
        blocks.push(SystemPromptBlock::text(part));
    }

    // Volatile parts (memory — cache at 5m)
    for part in &grouped.volatile {
        blocks.push(SystemPromptBlock::text(part));
    }

    if blocks.len() <= 1 && blocks[0].text == OAUTH_SYSTEM_PROMPT_PREFIX {
        // Only prefix — apply 5m cache to it
        blocks[0].cache_control = Some(CacheControl {
            cache_type: "ephemeral".into(),
            ttl: None,
        });
    } else if !grouped.volatile.is_empty() {
        // Has volatile content — 1h on last stable, 5m on last volatile
        let last_stable_idx = 1 + grouped.stable.len(); // offset by 1 for prefix
        if last_stable_idx > 1 && last_stable_idx <= blocks.len() {
            blocks[last_stable_idx - 1].cache_control = Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: Some("1h".into()),
            });
        }
        // 5m on last volatile (last block)
        if let Some(last) = blocks.last_mut() {
            last.cache_control = Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: None,
            });
        }
    } else if !grouped.stable.is_empty() {
        // Only stable content — 1h on last block
        if let Some(last) = blocks.last_mut() {
            last.cache_control = Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: Some("1h".into()),
            });
        }
    }

    serde_json::to_value(&blocks).expect("SystemPromptBlock serialization")
}

/// Build system prompt for API key connections (plain string).
fn build_system_prompt_plain(context: &Context) -> Option<Value> {
    let parts = compose_context_parts(context);
    if parts.is_empty() {
        None
    } else {
        Some(Value::String(parts.join("\n\n")))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tool conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Convert context tools to Anthropic format with optional cache control.
///
/// For OAuth: the last tool gets a 1h cache control breakpoint.
fn convert_tools(
    tools: &[tron_core::tools::Tool],
    is_oauth: bool,
) -> Vec<AnthropicTool> {
    let mut result: Vec<AnthropicTool> = tools
        .iter()
        .map(|t| AnthropicTool {
            name: t.name.clone(),
            description: t.description.clone(),
            input_schema: serde_json::to_value(&t.parameters).unwrap_or_default(),
            cache_control: None,
        })
        .collect();

    // Breakpoint 1: Last tool gets 1h cache (OAuth only)
    if is_oauth {
        if let Some(last) = result.last_mut() {
            last.cache_control = Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: Some("1h".into()),
            });
        }
    }

    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;
    use tron_core::content::AssistantContent;
    use tron_core::messages::{Context, Message, UserMessageContent};
    use tron_core::tools::{Tool, ToolParameterSchema};

    fn simple_context() -> Context {
        Context {
            system_prompt: Some("You are helpful.".into()),
            messages: vec![Message::user("hello")],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        }
    }

    fn make_tool(name: &str) -> Tool {
        Tool {
            name: name.into(),
            description: format!("{name} tool"),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: None,
                required: None,
                description: None,
                extra: Default::default(),
            },
        }
    }

    // ── User message conversion ──────────────────────────────────────────

    #[test]
    fn convert_user_text_message() {
        let content = UserMessageContent::Text("hello".into());
        let param = convert_user_message(&content);
        assert_eq!(param.role, "user");
        assert_eq!(param.content[0]["type"], "text");
        assert_eq!(param.content[0]["text"], "hello");
    }

    #[test]
    fn convert_user_image_block() {
        let content = UserMessageContent::Blocks(vec![
            UserContent::text("describe this"),
            UserContent::image("base64data", "image/png"),
        ]);
        let param = convert_user_message(&content);
        assert_eq!(param.content.len(), 2);
        assert_eq!(param.content[0]["type"], "text");
        assert_eq!(param.content[1]["type"], "image");
        assert_eq!(param.content[1]["source"]["type"], "base64");
        assert_eq!(param.content[1]["source"]["media_type"], "image/png");
    }

    #[test]
    fn convert_user_document_block() {
        let content = UserMessageContent::Blocks(vec![UserContent::Document {
            data: "pdfdata".into(),
            mime_type: "application/pdf".into(),
            file_name: Some("report.pdf".into()),
        }]);
        let param = convert_user_message(&content);
        assert_eq!(param.content[0]["type"], "document");
        assert_eq!(param.content[0]["source"]["media_type"], "application/pdf");
    }

    // ── Assistant message conversion ─────────────────────────────────────

    #[test]
    fn convert_assistant_text_only() {
        let content = vec![AssistantContent::text("response")];
        let id_mapping = HashMap::new();
        let param = convert_assistant_message(&content, &id_mapping);
        assert_eq!(param.role, "assistant");
        assert_eq!(param.content[0]["type"], "text");
        assert_eq!(param.content[0]["text"], "response");
    }

    #[test]
    fn convert_assistant_thinking_with_signature() {
        let content = vec![
            AssistantContent::Thinking {
                thinking: "let me think".into(),
                signature: Some("sig123".into()),
            },
            AssistantContent::text("answer"),
        ];
        let id_mapping = HashMap::new();
        let param = convert_assistant_message(&content, &id_mapping);
        assert_eq!(param.content.len(), 2);
        assert_eq!(param.content[0]["type"], "thinking");
        assert_eq!(param.content[0]["signature"], "sig123");
    }

    #[test]
    fn convert_assistant_thinking_without_signature_filtered() {
        let content = vec![
            AssistantContent::Thinking {
                thinking: "display only".into(),
                signature: None,
            },
            AssistantContent::text("answer"),
        ];
        let id_mapping = HashMap::new();
        let param = convert_assistant_message(&content, &id_mapping);
        // Thinking without signature should be filtered out
        assert_eq!(param.content.len(), 1);
        assert_eq!(param.content[0]["type"], "text");
    }

    #[test]
    fn convert_assistant_tool_use() {
        let mut args = Map::new();
        let _ = args.insert("cmd".into(), json!("ls"));
        let content = vec![AssistantContent::ToolUse {
            id: "toolu_01abc".into(),
            name: "bash".into(),
            arguments: args,
            thought_signature: None,
        }];
        let id_mapping = HashMap::new();
        let param = convert_assistant_message(&content, &id_mapping);
        assert_eq!(param.content[0]["type"], "tool_use");
        assert_eq!(param.content[0]["id"], "toolu_01abc");
        assert_eq!(param.content[0]["name"], "bash");
        assert_eq!(param.content[0]["input"]["cmd"], "ls");
    }

    #[test]
    fn convert_assistant_tool_use_remaps_openai_id() {
        let mut args = Map::new();
        let _ = args.insert("cmd".into(), json!("ls"));
        let content = vec![AssistantContent::ToolUse {
            id: "call_abc123xyz".into(),
            name: "bash".into(),
            arguments: args,
            thought_signature: None,
        }];
        // Build mapping that remaps the OpenAI ID
        let id_mapping = build_tool_call_id_mapping(&["call_abc123xyz"], IdFormat::Anthropic);
        let param = convert_assistant_message(&content, &id_mapping);
        let id = param.content[0]["id"].as_str().unwrap();
        assert!(
            id.starts_with("toolu_remap_"),
            "Should remap to Anthropic format: {id}"
        );
    }

    // ── Tool result conversion ───────────────────────────────────────────

    #[test]
    fn convert_tool_result_text() {
        let content = ToolResultMessageContent::Text("output".into());
        let id_mapping = HashMap::new();
        let param = convert_tool_result("toolu_01abc", &content, None, &id_mapping);
        assert_eq!(param.role, "user");
        assert_eq!(param.content[0]["type"], "tool_result");
        assert_eq!(param.content[0]["tool_use_id"], "toolu_01abc");
        assert_eq!(param.content[0]["content"][0]["text"], "output");
        assert!(param.content[0].get("is_error").is_none());
    }

    #[test]
    fn convert_tool_result_error() {
        let content = ToolResultMessageContent::Text("failed".into());
        let id_mapping = HashMap::new();
        let param = convert_tool_result("toolu_01abc", &content, Some(true), &id_mapping);
        assert_eq!(param.content[0]["is_error"], true);
    }

    #[test]
    fn convert_tool_result_with_image() {
        let content = ToolResultMessageContent::Blocks(vec![
            ToolResultContent::text("screenshot taken"),
            ToolResultContent::image("imgdata", "image/png"),
        ]);
        let id_mapping = HashMap::new();
        let param = convert_tool_result("toolu_01abc", &content, None, &id_mapping);
        let inner = &param.content[0]["content"];
        assert_eq!(inner[0]["type"], "text");
        assert_eq!(inner[1]["type"], "image");
        assert_eq!(inner[1]["source"]["media_type"], "image/png");
    }

    // ── System prompt ────────────────────────────────────────────────────

    #[test]
    fn system_prompt_api_key_plain_string() {
        let ctx = simple_context();
        let system = build_system_prompt(&ctx, false);
        assert!(system.is_some());
        assert!(system.unwrap().is_string());
    }

    #[test]
    fn system_prompt_api_key_none_when_empty() {
        let ctx = Context::default();
        let system = build_system_prompt(&ctx, false);
        assert!(system.is_none());
    }

    #[test]
    fn system_prompt_oauth_returns_array() {
        let ctx = simple_context();
        let system = build_system_prompt(&ctx, true);
        assert!(system.is_some());
        let arr = system.unwrap();
        assert!(arr.is_array());
        let blocks = arr.as_array().unwrap();
        // First block is the OAuth prefix
        assert_eq!(blocks[0]["text"], OAUTH_SYSTEM_PROMPT_PREFIX);
    }

    #[test]
    fn system_prompt_oauth_has_cache_control() {
        let ctx = Context {
            system_prompt: Some("You are helpful.".into()),
            rules_content: Some("Rule 1".into()),
            ..Default::default()
        };
        let system = build_system_prompt(&ctx, true).unwrap();
        let blocks = system.as_array().unwrap();
        // Last block should have cache_control
        let last = blocks.last().unwrap();
        assert!(last.get("cache_control").is_some());
    }

    #[test]
    fn system_prompt_oauth_with_volatile_has_two_cache_tiers() {
        let ctx = Context {
            system_prompt: Some("You are helpful.".into()),
            rules_content: Some("Rule 1".into()),
            // memory_content is stable — need volatile content for two tiers
            skill_context: Some("Available skill: /commit".into()),
            ..Default::default()
        };
        let system = build_system_prompt(&ctx, true).unwrap();
        let blocks = system.as_array().unwrap();

        // Should have cache_control with 1h on last stable, 5m on last volatile
        let has_1h = blocks
            .iter()
            .any(|b| b["cache_control"]["ttl"].as_str() == Some("1h"));
        let has_default = blocks
            .iter()
            .any(|b| {
                b.get("cache_control").is_some()
                    && (b["cache_control"].get("ttl").is_none()
                        || b["cache_control"]["ttl"].is_null())
            });
        assert!(has_1h, "Should have 1h cache on stable content");
        assert!(has_default, "Should have default (5m) cache on volatile content");
    }

    // ── Tool conversion ──────────────────────────────────────────────────

    #[test]
    fn convert_tools_basic() {
        let tools = vec![make_tool("bash"), make_tool("read")];
        let result = convert_tools(&tools, false);
        assert_eq!(result.len(), 2);
        assert_eq!(result[0].name, "bash");
        assert_eq!(result[1].name, "read");
        assert!(result[0].cache_control.is_none());
        assert!(result[1].cache_control.is_none());
    }

    #[test]
    fn convert_tools_oauth_last_has_cache() {
        let tools = vec![make_tool("bash"), make_tool("read")];
        let result = convert_tools(&tools, true);
        assert!(result[0].cache_control.is_none());
        assert!(result[1].cache_control.is_some());
        assert_eq!(result[1].cache_control.as_ref().unwrap().ttl.as_deref(), Some("1h"));
    }

    #[test]
    fn convert_tools_empty() {
        let tools: Vec<Tool> = vec![];
        let result = convert_tools(&tools, true);
        assert!(result.is_empty());
    }

    // ── Full context conversion ──────────────────────────────────────────

    #[test]
    fn convert_context_full() {
        let ctx = Context {
            system_prompt: Some("You are helpful.".into()),
            messages: vec![
                Message::user("hello"),
                Message::Assistant {
                    content: vec![AssistantContent::text("hi there")],
                    usage: None,
                    cost: None,
                    stop_reason: None,
                    thinking: None,
                },
            ],
            tools: Some(vec![make_tool("bash")]),
            ..Default::default()
        };

        let (system, messages, tools) = convert_context(&ctx, true);
        assert!(system.is_some());
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[1].role, "assistant");
        assert!(tools.is_some());
        assert_eq!(tools.unwrap().len(), 1);
    }

    // ── ID mapping ───────────────────────────────────────────────────────

    #[test]
    fn build_id_mapping_from_messages() {
        let messages = vec![
            Message::user("hi"),
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_abc123def456".into(),
                    name: "bash".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];
        let mapping = build_id_mapping(&messages);
        // OpenAI-format ID should get a mapping entry
        assert!(!mapping.is_empty());
    }

    #[test]
    fn build_id_mapping_empty_for_anthropic_ids() {
        let messages = vec![
            Message::user("hi"),
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01abc".into(),
                    name: "bash".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];
        let mapping = build_id_mapping(&messages);
        // Anthropic-format IDs don't need remapping
        assert!(mapping.is_empty());
    }
}
