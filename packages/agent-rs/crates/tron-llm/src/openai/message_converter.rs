//! # `OpenAI` Message Converter
//!
//! Converts between Tron message format and `OpenAI` Responses API format.
//! Handles tool call ID remapping for cross-provider compatibility.
//!
//! Key behaviors:
//! - User messages → `input_text` / `input_image` content
//! - Assistant text → `output_text` content
//! - Tool calls → `function_call` items with remapped IDs
//! - Tool results → `function_call_output` items (truncated at 16k)
//! - Documents → placeholder text (`OpenAI` doesn't support documents directly)

use tron_core::content::{AssistantContent, ToolResultContent, UserContent};
use tron_core::messages::{Message, ToolResultMessageContent, UserMessageContent};
use tron_core::tools::Tool;
use crate::{build_tool_call_id_mapping, remap_tool_call_id, IdFormat};

use super::types::{MessageContent, ResponsesInputItem, ResponsesTool, TOOL_RESULT_MAX_LENGTH};

/// Convert Tron messages to Responses API input format.
///
/// Tool call IDs from other providers (e.g., Anthropic's `toolu_` prefix)
/// are remapped to `OpenAI`-compatible `call_` format for cross-provider support.
#[must_use]
pub fn convert_to_responses_input(messages: &[Message]) -> Vec<ResponsesInputItem> {
    let mut input = Vec::new();

    // Build tool call ID mapping for cross-provider switching
    let all_tool_call_ids = collect_tool_call_ids(messages);
    let id_refs: Vec<&str> = all_tool_call_ids.iter().map(String::as_str).collect();
    let id_mapping = build_tool_call_id_mapping(&id_refs, IdFormat::OpenAi);

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                convert_user_message(content, &mut input);
            }
            Message::Assistant { content, .. } => {
                convert_assistant_message(content, &id_mapping, &mut input);
            }
            Message::ToolResult {
                tool_call_id,
                content,
                ..
            } => {
                convert_tool_result(tool_call_id, content, &id_mapping, &mut input);
            }
        }
    }

    input
}

/// Convert Tron tools to Responses API format.
#[must_use]
pub fn convert_tools(tools: &[Tool]) -> Vec<ResponsesTool> {
    tools
        .iter()
        .map(|t| ResponsesTool {
            tool_type: "function".into(),
            name: t.name.clone(),
            description: t.description.clone(),
            parameters: serde_json::to_value(&t.parameters).unwrap_or_default(),
        })
        .collect()
}

/// Generate a tool clarification message for the first turn.
///
/// Since `OpenAI` Codex has its own built-in system instructions that reference
/// tools we don't use (shell, `apply_patch`, etc.), we prepend this message to
/// clarify the actual available tools.
#[must_use]
pub fn generate_tool_clarification_message(
    tools: &[Tool],
    working_directory: Option<&str>,
) -> String {
    let tool_descriptions: Vec<String> = tools
        .iter()
        .map(|t| {
            let required = serde_json::to_value(&t.parameters)
                .ok()
                .and_then(|v| v.get("required").cloned())
                .and_then(|v| {
                    v.as_array().map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(String::from))
                            .collect::<Vec<_>>()
                            .join(", ")
                    })
                })
                .unwrap_or_else(|| "none".into());
            format!("- **{}**: {} (required params: {required})", t.name, t.description)
        })
        .collect();

    let cwd_line = working_directory
        .map(|d| format!("\nCurrent working directory: {d}"))
        .unwrap_or_default();

    format!(
        "[TRON CONTEXT]\n\
        You are Tron, an AI coding assistant with full access to the user's file system.\n\
        {cwd_line}\n\
        \n\
        ## Available Tools\n\
        The tools mentioned in the system instructions (shell, apply_patch, etc.) are NOT available. \
        Use ONLY these tools:\n\
        \n\
        {tool_list}\n\
        \n\
        ## Bash Tool Capabilities\n\
        The Bash tool runs commands on the user's local machine with FULL capabilities:\n\
        - **Network access**: Use curl, wget, or other tools to fetch URLs, APIs, websites\n\
        - **File system**: Full read/write access to files and directories\n\
        - **Git operations**: Clone, commit, push, pull, etc.\n\
        - **Package managers**: npm, pip, brew, apt, etc.\n\
        - **Any installed CLI tools**: rg, jq, python, node, etc.\n\
        \n\
        When asked to visit a website or fetch data from the internet, USE the Bash tool with curl. \
        Example: `curl -s https://example.com`\n\
        \n\
        ## Important Rules\n\
        1. You MUST provide ALL required parameters when calling tools - never call with empty arguments\n\
        2. For file paths, provide the complete path (e.g., \"src/index.ts\" or \"/absolute/path/file.txt\")\n\
        3. Confidently interpret and explain results from tool calls - you have full context of what was returned\n\
        4. Be helpful, accurate, and efficient when working with code\n\
        5. Read existing files to understand context before making changes\n\
        6. Make targeted, minimal edits rather than rewriting entire files",
        tool_list = tool_descriptions.join("\n")
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Collect all tool call IDs from assistant messages.
fn collect_tool_call_ids(messages: &[Message]) -> Vec<String> {
    let mut ids = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::ToolUse { id, .. } = block {
                    ids.push(id.clone());
                }
            }
        }
    }
    ids
}

/// Convert a user message to Responses API input items.
fn convert_user_message(content: &UserMessageContent, input: &mut Vec<ResponsesInputItem>) {
    match content {
        UserMessageContent::Text(text) => {
            input.push(ResponsesInputItem::Message {
                role: "user".into(),
                content: vec![MessageContent::InputText { text: text.clone() }],
                id: None,
            });
        }
        UserMessageContent::Blocks(blocks) => {
            let content_parts: Vec<MessageContent> = blocks
                .iter()
                .map(|block| match block {
                    UserContent::Text { text } => {
                        MessageContent::InputText { text: text.clone() }
                    }
                    UserContent::Image { data, mime_type } => MessageContent::InputImage {
                        image_url: format!("data:{mime_type};base64,{data}"),
                        detail: Some("auto".into()),
                    },
                    UserContent::Document {
                        mime_type,
                        file_name,
                        ..
                    } => {
                        let name = file_name.as_deref().unwrap_or("unnamed");
                        MessageContent::InputText {
                            text: format!("[Document: {name} ({mime_type})]"),
                        }
                    }
                })
                .collect();

            if !content_parts.is_empty() {
                input.push(ResponsesInputItem::Message {
                    role: "user".into(),
                    content: content_parts,
                    id: None,
                });
            }
        }
    }
}

/// Convert an assistant message to Responses API input items.
fn convert_assistant_message(
    content: &[AssistantContent],
    id_mapping: &std::collections::HashMap<String, String>,
    input: &mut Vec<ResponsesInputItem>,
) {
    // Collect text parts
    let text_parts: Vec<MessageContent> = content
        .iter()
        .filter_map(|block| {
            if let AssistantContent::Text { text } = block {
                Some(MessageContent::OutputText { text: text.clone() })
            } else {
                None
            }
        })
        .collect();

    if !text_parts.is_empty() {
        input.push(ResponsesInputItem::Message {
            role: "assistant".into(),
            content: text_parts,
            id: None,
        });
    }

    // Convert tool calls to function_call items
    for block in content {
        if let AssistantContent::ToolUse {
            id, name, arguments, ..
        } = block
        {
            let remapped_id = remap_tool_call_id(id, id_mapping).to_string();
            input.push(ResponsesInputItem::FunctionCall {
                id: None,
                call_id: remapped_id,
                name: name.clone(),
                arguments: serde_json::to_string(arguments).unwrap_or_else(|_| "{}".into()),
            });
        }
    }
}

/// Convert a tool result to a Responses API `function_call_output` item.
fn convert_tool_result(
    tool_call_id: &str,
    content: &ToolResultMessageContent,
    id_mapping: &std::collections::HashMap<String, String>,
    input: &mut Vec<ResponsesInputItem>,
) {
    let output_text = match content {
        ToolResultMessageContent::Text(text) => text.clone(),
        ToolResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| {
                if let ToolResultContent::Text { text } = block {
                    Some(text.as_str())
                } else {
                    None
                }
            })
            .collect::<Vec<_>>()
            .join("\n"),
    };

    // Truncate long outputs (Codex has 16k limit per output)
    let truncated = if output_text.len() > TOOL_RESULT_MAX_LENGTH {
        let mut t = output_text[..TOOL_RESULT_MAX_LENGTH].to_string();
        t.push_str("\n... [truncated]");
        t
    } else {
        output_text
    };

    let remapped_id = remap_tool_call_id(tool_call_id, id_mapping).to_string();
    input.push(ResponsesInputItem::FunctionCallOutput {
        call_id: remapped_id,
        output: truncated,
    });
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use serde_json::{Map, Value, json};
    use tron_core::content::AssistantContent;
    use tron_core::messages::{Message, ToolResultMessageContent, UserMessageContent};
    use tron_core::tools::{Tool, ToolParameterSchema};

    fn make_tool(name: &str, desc: &str) -> Tool {
        Tool {
            name: name.into(),
            description: desc.into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some(Map::new()),
                required: Some(vec![]),
                description: None,
                extra: Map::new(),
            },
        }
    }

    fn make_tool_with_required(name: &str, desc: &str, required: Vec<&str>) -> Tool {
        let mut props = Map::new();
        for r in &required {
            let mut prop = Map::new();
            prop.insert("type".into(), json!("string"));
            props.insert((*r).to_string(), Value::Object(prop));
        }
        Tool {
            name: name.into(),
            description: desc.into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some(props),
                required: Some(required.into_iter().map(String::from).collect()),
                description: None,
                extra: Map::new(),
            },
        }
    }

    // ── convert_to_responses_input ──────────────────────────────────

    #[test]
    fn converts_string_user_messages() {
        let messages = vec![Message::user("Hello")];
        let result = convert_to_responses_input(&messages);

        assert_eq!(result.len(), 1);
        match &result[0] {
            ResponsesInputItem::Message { role, content, .. } => {
                assert_eq!(role, "user");
                assert_eq!(content.len(), 1);
                match &content[0] {
                    MessageContent::InputText { text } => assert_eq!(text, "Hello"),
                    _ => panic!("expected InputText"),
                }
            }
            _ => panic!("expected Message"),
        }
    }

    #[test]
    fn converts_user_text_content_blocks() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::text("Part 1"),
                UserContent::text("Part 2"),
            ]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            assert_eq!(content.len(), 2);
        } else {
            panic!("expected Message");
        }
    }

    #[test]
    fn converts_image_content() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::image(
                "base64data",
                "image/png",
            )]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            match &content[0] {
                MessageContent::InputImage { image_url, detail } => {
                    assert_eq!(image_url, "data:image/png;base64,base64data");
                    assert_eq!(detail.as_deref(), Some("auto"));
                }
                _ => panic!("expected InputImage"),
            }
        }
    }

    #[test]
    fn converts_document_to_placeholder() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::Document {
                data: "pdfdata".into(),
                mime_type: "application/pdf".into(),
                file_name: Some("doc.pdf".into()),
            }]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            match &content[0] {
                MessageContent::InputText { text } => {
                    assert_eq!(text, "[Document: doc.pdf (application/pdf)]");
                }
                _ => panic!("expected InputText"),
            }
        }
    }

    #[test]
    fn converts_assistant_text() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::text("Response")],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::Message {
            role, content, ..
        } = &result[0]
        {
            assert_eq!(role, "assistant");
            match &content[0] {
                MessageContent::OutputText { text } => assert_eq!(text, "Response"),
                _ => panic!("expected OutputText"),
            }
        }
    }

    #[test]
    fn converts_assistant_tool_calls() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/test.txt"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_abc".into(),
                name: "read_file".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        assert!(func_call.is_some());
        if let ResponsesInputItem::FunctionCall { name, arguments, .. } = func_call.unwrap() {
            assert_eq!(name, "read_file");
            assert!(arguments.contains("path"));
        }
    }

    #[test]
    fn converts_tool_results() {
        let messages = vec![Message::ToolResult {
            tool_call_id: "call_abc".into(),
            content: ToolResultMessageContent::Text("File contents here".into()),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert_eq!(output, "File contents here");
        } else {
            panic!("expected FunctionCallOutput");
        }
    }

    #[test]
    fn converts_tool_result_content_blocks() {
        let messages = vec![Message::ToolResult {
            tool_call_id: "call_abc".into(),
            content: ToolResultMessageContent::Blocks(vec![
                ToolResultContent::text("Line 1"),
                ToolResultContent::text("Line 2"),
            ]),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert_eq!(output, "Line 1\nLine 2");
        }
    }

    #[test]
    fn truncates_long_tool_results() {
        let long_output = "x".repeat(20000);
        let messages = vec![Message::ToolResult {
            tool_call_id: "call_abc".into(),
            content: ToolResultMessageContent::Text(long_output),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert!(output.len() <= TOOL_RESULT_MAX_LENGTH + 20);
            assert!(output.contains("[truncated]"));
        }
    }

    #[test]
    fn handles_empty_tool_call_arguments() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_1".into(),
                name: "get_status".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        if let Some(ResponsesInputItem::FunctionCall { arguments, .. }) = func_call {
            assert_eq!(arguments, "{}");
        }
    }

    #[test]
    fn remaps_anthropic_tool_call_ids() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/test"));
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01abc".into(),
                    name: "read_file".into(),
                    arguments: args,
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_01abc".into(),
                content: ToolResultMessageContent::Text("result".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        // Both the function_call and function_call_output should use remapped IDs
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        let func_output = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCallOutput { .. }));

        if let Some(ResponsesInputItem::FunctionCall { call_id, .. }) = func_call {
            assert!(call_id.starts_with("call_"), "expected call_ prefix, got: {call_id}");
        }
        if let Some(ResponsesInputItem::FunctionCallOutput { call_id, .. }) = func_output {
            assert!(call_id.starts_with("call_"), "expected call_ prefix, got: {call_id}");
        }
    }

    #[test]
    fn preserves_openai_tool_call_ids() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_existing".into(),
                    name: "bash".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "call_existing".into(),
                content: ToolResultMessageContent::Text("ok".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        if let Some(ResponsesInputItem::FunctionCall { call_id, .. }) = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }))
        {
            assert_eq!(call_id, "call_existing");
        }
    }

    #[test]
    fn handles_mixed_conversation() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/f.txt"));
        let messages = vec![
            Message::user("Read file"),
            Message::Assistant {
                content: vec![
                    AssistantContent::text("Reading..."),
                    AssistantContent::ToolUse {
                        id: "call_1".into(),
                        name: "read".into(),
                        arguments: args,
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "call_1".into(),
                content: ToolResultMessageContent::Text("file data".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        // user message + assistant text + function_call + function_call_output
        assert_eq!(result.len(), 4);
    }

    #[test]
    fn empty_messages_returns_empty() {
        let result = convert_to_responses_input(&[]);
        assert!(result.is_empty());
    }

    // ── convert_tools ──────────────────────────────────────────────

    #[test]
    fn converts_tools_to_responses_format() {
        let tools = vec![make_tool("read_file", "Read a file from disk")];
        let result = convert_tools(&tools);

        assert_eq!(result.len(), 1);
        assert_eq!(result[0].tool_type, "function");
        assert_eq!(result[0].name, "read_file");
        assert_eq!(result[0].description, "Read a file from disk");
    }

    #[test]
    fn converts_multiple_tools() {
        let tools = vec![
            make_tool("tool_a", "Tool A"),
            make_tool("tool_b", "Tool B"),
        ];
        let result = convert_tools(&tools);
        assert_eq!(result.len(), 2);
    }

    // ── generate_tool_clarification_message ─────────────────────────

    #[test]
    fn clarification_includes_tool_names() {
        let tools = vec![make_tool_with_required("Bash", "Run bash commands", vec!["command"])];
        let result = generate_tool_clarification_message(&tools, None);

        assert!(result.contains("Bash"));
        assert!(result.contains("Run bash commands"));
        assert!(result.contains("required params: command"));
    }

    #[test]
    fn clarification_includes_working_directory() {
        let tools = vec![];
        let result = generate_tool_clarification_message(&tools, Some("/home/user/project"));
        assert!(result.contains("/home/user/project"));
    }

    #[test]
    fn clarification_includes_tron_identity() {
        let result = generate_tool_clarification_message(&[], None);
        assert!(result.contains("TRON"));
        assert!(result.contains("AI coding assistant"));
    }

    #[test]
    fn clarification_includes_bash_capabilities() {
        let result = generate_tool_clarification_message(&[], None);
        assert!(result.contains("Bash Tool Capabilities"));
        assert!(result.contains("Network access"));
        assert!(result.contains("curl"));
    }
}
