//! Converts [`Context`] messages to Gemini API format.
//!
//! Handles text, images, PDFs, tool calls (with `thoughtSignature`), and tool results.
//! Sanitizes JSON schemas by removing unsupported properties (`additionalProperties`, `$schema`).

use tron_core::content::{AssistantContent, UserContent};
use tron_core::messages::{Context, Message, ToolResultMessageContent, UserMessageContent};
use tron_core::tools::Tool;
use tron_llm::id_remapping::{build_tool_call_id_mapping, remap_tool_call_id, IdFormat};

use crate::types::{
    FunctionCallData, FunctionDeclaration, FunctionResponseData, GeminiContent, GeminiPart,
    GeminiTool, InlineDataContent, TOOL_RESULT_MAX_LENGTH,
};

/// Placeholder thought signature for historical function calls from other providers.
///
/// When a tool call doesn't have a thought signature (e.g., it came from Anthropic
/// or `OpenAI`), this placeholder is used to satisfy the Gemini 3 validator.
const SKIP_THOUGHT_SIGNATURE: &str = "skip_thought_signature_validator";

/// Collect all tool call IDs from assistant messages for cross-provider remapping.
fn collect_tool_call_ids(messages: &[Message]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|m| match m {
            Message::Assistant { content, .. } => {
                let ids: Vec<String> = content
                    .iter()
                    .filter_map(|c| match c {
                        AssistantContent::ToolUse { id, .. } => Some(id.clone()),
                        _ => None,
                    })
                    .collect();
                if ids.is_empty() { None } else { Some(ids) }
            }
            _ => None,
        })
        .flatten()
        .collect()
}

/// Convert context messages to Gemini API content format.
///
/// Builds a tool call ID mapping for cross-provider remapping, then converts
/// each message to `GeminiContent` with appropriate parts.
pub fn convert_messages(context: &Context) -> Vec<GeminiContent> {
    let messages = &context.messages;
    if messages.is_empty() {
        return vec![];
    }

    let all_tool_call_ids = collect_tool_call_ids(messages);
    let id_refs: Vec<&str> = all_tool_call_ids.iter().map(String::as_str).collect();
    let id_mapping = build_tool_call_id_mapping(&id_refs, IdFormat::OpenAi);

    let mut contents = Vec::new();

    for message in messages {
        match message {
            Message::User { content, .. } => {
                let parts = convert_user_content(content);
                if !parts.is_empty() {
                    contents.push(GeminiContent {
                        role: "user".into(),
                        parts,
                    });
                }
            }
            Message::Assistant { content, .. } => {
                let mut parts = Vec::new();

                for block in content {
                    match block {
                        AssistantContent::Text { text } => {
                            if !text.is_empty() {
                                parts.push(GeminiPart::Text {
                                    text: text.clone(),
                                    thought: None,
                                    thought_signature: None,
                                });
                            }
                        }
                        AssistantContent::ToolUse {
                            name,
                            arguments,
                            thought_signature,
                            ..
                        } => {
                            let args =
                                serde_json::Value::Object(arguments.clone());

                            let thought_sig = thought_signature
                                .clone()
                                .unwrap_or_else(|| SKIP_THOUGHT_SIGNATURE.to_string());

                            parts.push(GeminiPart::FunctionCall {
                                function_call: FunctionCallData {
                                    name: name.clone(),
                                    args,
                                },
                                thought_signature: Some(thought_sig),
                            });
                        }
                        AssistantContent::Thinking { .. } => {
                            // Thinking blocks are not sent back to Gemini
                        }
                    }
                }

                if !parts.is_empty() {
                    contents.push(GeminiContent {
                        role: "model".into(),
                        parts,
                    });
                }
            }
            Message::ToolResult {
                tool_call_id,
                content,
                ..
            } => {
                let remapped_id = remap_tool_call_id(tool_call_id, &id_mapping);
                let result_text = extract_tool_result_text(content);
                let truncated = truncate_tool_result(&result_text);

                contents.push(GeminiContent {
                    role: "user".into(),
                    parts: vec![GeminiPart::FunctionResponse {
                        function_response: FunctionResponseData {
                            name: "tool_result".into(),
                            response: serde_json::json!({
                                "result": truncated,
                                "tool_call_id": remapped_id,
                            }),
                        },
                    }],
                });
            }
        }
    }

    contents
}

/// Extract text from tool result message content.
fn extract_tool_result_text(content: &ToolResultMessageContent) -> String {
    match content {
        ToolResultMessageContent::Text(text) => text.clone(),
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

/// Convert user message content to Gemini parts.
fn convert_user_content(content: &UserMessageContent) -> Vec<GeminiPart> {
    match content {
        UserMessageContent::Text(text) => {
            if text.is_empty() {
                vec![]
            } else {
                vec![GeminiPart::Text {
                    text: text.clone(),
                    thought: None,
                    thought_signature: None,
                }]
            }
        }
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                UserContent::Text { text } => Some(GeminiPart::Text {
                    text: text.clone(),
                    thought: None,
                    thought_signature: None,
                }),
                UserContent::Image { data, mime_type } => Some(GeminiPart::InlineData {
                    inline_data: InlineDataContent {
                        mime_type: mime_type.clone(),
                        data: data.clone(),
                    },
                }),
                UserContent::Document {
                    data, mime_type, ..
                } => {
                    if mime_type == "application/pdf" {
                        Some(GeminiPart::InlineData {
                            inline_data: InlineDataContent {
                                mime_type: "application/pdf".into(),
                                data: data.clone(),
                            },
                        })
                    } else {
                        None // Unsupported document type
                    }
                }
            })
            .collect(),
    }
}

/// Convert tools to Gemini API format.
///
/// Returns a single-element array with all function declarations.
pub fn convert_tools(tools: &[Tool]) -> Vec<GeminiTool> {
    let declarations: Vec<FunctionDeclaration> = tools
        .iter()
        .map(|tool| {
            let schema = serde_json::to_value(&tool.parameters).unwrap_or_default();
            let params = sanitize_schema_for_gemini(&schema);

            FunctionDeclaration {
                name: tool.name.clone(),
                description: tool.description.clone(),
                parameters: params,
            }
        })
        .collect();

    if declarations.is_empty() {
        return vec![];
    }

    vec![GeminiTool {
        function_declarations: declarations,
    }]
}

/// Sanitize a JSON schema for the Gemini API.
///
/// Removes unsupported properties:
/// - `additionalProperties` — Gemini doesn't support it
/// - `$schema` — not needed for API calls
pub fn sanitize_schema_for_gemini(schema: &serde_json::Value) -> serde_json::Value {
    match schema {
        serde_json::Value::Object(map) => {
            let mut cleaned = serde_json::Map::new();
            for (key, value) in map {
                if key == "additionalProperties" || key == "$schema" {
                    continue;
                }
                let _ = cleaned.insert(key.clone(), sanitize_schema_for_gemini(value));
            }
            serde_json::Value::Object(cleaned)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(sanitize_schema_for_gemini).collect())
        }
        other => other.clone(),
    }
}

/// Truncate tool result content if it exceeds the max length.
fn truncate_tool_result(content: &str) -> String {
    if content.len() <= TOOL_RESULT_MAX_LENGTH {
        content.to_string()
    } else {
        let truncated = &content[..TOOL_RESULT_MAX_LENGTH];
        format!("{truncated}\n\n[Content truncated — {TOOL_RESULT_MAX_LENGTH} char limit]")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use serde_json::Map;
    use tron_core::content::AssistantContent;
    use tron_core::messages::UserMessageContent;

    fn ctx(messages: Vec<Message>) -> Context {
        Context {
            messages,
            system_prompt: None,
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

    // ── convert_messages ─────────────────────────────────────────────

    #[test]
    fn empty_messages_returns_empty() {
        assert!(convert_messages(&ctx(vec![])).is_empty());
    }

    #[test]
    fn converts_user_text_message() {
        let context = ctx(vec![Message::user("hello")]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
        match &contents[0].parts[0] {
            GeminiPart::Text { text, .. } => assert_eq!(text, "hello"),
            _ => panic!("Expected text part"),
        }
    }

    #[test]
    fn converts_user_blocks_message() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::text("hello")]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
    }

    #[test]
    fn converts_assistant_text() {
        let context = ctx(vec![Message::assistant("response")]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "model");
    }

    #[test]
    fn converts_assistant_tool_calls_with_thought_signature() {
        let mut args = Map::new();
        args.insert("command".into(), serde_json::json!("ls"));
        let context = ctx(vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_123".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: Some("sig-abc".into()),
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        match &contents[0].parts[0] {
            GeminiPart::FunctionCall {
                function_call,
                thought_signature,
            } => {
                assert_eq!(function_call.name, "bash");
                assert_eq!(thought_signature.as_deref(), Some("sig-abc"));
            }
            _ => panic!("Expected function call part"),
        }
    }

    #[test]
    fn tool_call_without_signature_uses_placeholder() {
        let context = ctx(vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "toolu_123".into(),
                name: "read".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::FunctionCall {
                thought_signature, ..
            } => {
                assert_eq!(
                    thought_signature.as_deref(),
                    Some(SKIP_THOUGHT_SIGNATURE)
                );
            }
            _ => panic!("Expected function call"),
        }
    }

    #[test]
    fn converts_tool_result() {
        let context = ctx(vec![Message::ToolResult {
            tool_call_id: "call_abc".into(),
            content: ToolResultMessageContent::Text("result text".into()),
            is_error: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
        match &contents[0].parts[0] {
            GeminiPart::FunctionResponse {
                function_response, ..
            } => {
                assert_eq!(function_response.name, "tool_result");
            }
            _ => panic!("Expected function response"),
        }
    }

    #[test]
    fn converts_image_content() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::image(
                "base64data",
                "image/png",
            )]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::InlineData { inline_data } => {
                assert_eq!(inline_data.mime_type, "image/png");
                assert_eq!(inline_data.data, "base64data");
            }
            _ => panic!("Expected inline data"),
        }
    }

    #[test]
    fn converts_pdf_document() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::Document {
                data: "pdfdata".into(),
                mime_type: "application/pdf".into(),
                file_name: None,
            }]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::InlineData { inline_data } => {
                assert_eq!(inline_data.mime_type, "application/pdf");
            }
            _ => panic!("Expected inline data for PDF"),
        }
    }

    // ── convert_tools ────────────────────────────────────────────────

    #[test]
    fn converts_tools_to_gemini_format() {
        let mut props = serde_json::Map::new();
        props.insert(
            "command".into(),
            serde_json::json!({"type": "string"}),
        );
        let tools = vec![Tool {
            name: "bash".into(),
            description: "Run a command".into(),
            parameters: tron_core::tools::ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some(props),
                required: Some(vec!["command".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }];
        let gemini_tools = convert_tools(&tools);
        assert_eq!(gemini_tools.len(), 1);
        assert_eq!(gemini_tools[0].function_declarations.len(), 1);
        assert_eq!(gemini_tools[0].function_declarations[0].name, "bash");
    }

    #[test]
    fn empty_tools_returns_empty() {
        let tools: Vec<Tool> = vec![];
        assert!(convert_tools(&tools).is_empty());
    }

    // ── sanitize_schema ──────────────────────────────────────────────

    #[test]
    fn sanitize_removes_additional_properties() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {"x": {"type": "string"}},
            "additionalProperties": false,
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(sanitized.get("additionalProperties").is_none());
        assert_eq!(sanitized["type"], "object");
    }

    #[test]
    fn sanitize_removes_dollar_schema() {
        let schema = serde_json::json!({
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(sanitized.get("$schema").is_none());
    }

    #[test]
    fn sanitize_recurses_into_nested_objects() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "nested": {
                    "type": "object",
                    "additionalProperties": true,
                }
            }
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(sanitized["properties"]["nested"]
            .get("additionalProperties")
            .is_none());
    }

    // ── truncate_tool_result ─────────────────────────────────────────

    #[test]
    fn short_result_not_truncated() {
        let result = truncate_tool_result("short");
        assert_eq!(result, "short");
    }

    #[test]
    fn long_result_truncated() {
        let long_text = "x".repeat(TOOL_RESULT_MAX_LENGTH + 100);
        let result = truncate_tool_result(&long_text);
        assert!(result.len() < long_text.len());
        assert!(result.contains("[Content truncated"));
    }
}
