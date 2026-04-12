//! Message format conversion: Tron messages → Ollama native `/api/chat` format.
//!
//! Ollama's native API is similar to OpenAI chat completions but differs in two
//! key ways for tool calling:
//!
//! - **Tool call arguments** are JSON objects, not JSON-encoded strings.
//! - **Tool result messages** use `tool_name` (function name) instead of `tool_call_id`.
//!
//! This module converts Tron's internal message types to the native wire format.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::content::{AssistantContent, UserContent};
use crate::core::messages::{Message, ToolResultMessageContent, UserMessageContent};
use crate::core::tools::Tool;
use crate::llm::id_remapping::{IdFormat, build_tool_call_id_mapping, remap_tool_call_id};

// ─── Wire types ──────────────────────────────────────────────────────────────

/// A chat message in Ollama's native `/api/chat` format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatMessage {
    /// Message role: `"system"`, `"user"`, `"assistant"`, or `"tool"`.
    pub role: String,
    /// Message content (text or multimodal blocks).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    /// Tool calls made by the assistant.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ChatToolCall>>,
    /// Tool name (for tool result messages).
    ///
    /// Ollama's native `/api/chat` uses `tool_name` (the function name) to match
    /// results to calls, not `tool_call_id` like OpenAI's API.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

/// A tool call in Ollama's native format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatToolCall {
    /// Unique tool call ID.
    pub id: String,
    /// Always `"function"`.
    #[serde(rename = "type")]
    pub call_type: String,
    /// Function name and arguments.
    pub function: ChatFunction,
}

/// Function name + arguments in a tool call.
///
/// Uses `Value` (not `String`) for `arguments` because Ollama's native `/api/chat`
/// endpoint expects a JSON object, not a JSON-encoded string like OpenAI's API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatFunction {
    /// Function name.
    pub name: String,
    /// Arguments as a JSON object (native Ollama format, NOT a string).
    pub arguments: Value,
}

/// Tool definition for Ollama's native API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatToolDef {
    /// Always `"function"`.
    #[serde(rename = "type")]
    pub tool_type: String,
    /// Function definition.
    pub function: ChatFunctionDef,
}

/// Function definition within a tool.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatFunctionDef {
    /// Function name.
    pub name: String,
    /// Description.
    pub description: String,
    /// Parameter schema (JSON Schema).
    pub parameters: Value,
}

// ─── Conversion functions ────────────────────────────────────────────────────

/// Build a tool call ID mapping for all messages (Anthropic → OpenAI format).
fn build_id_mapping(messages: &[Message]) -> HashMap<String, String> {
    let mut ids = Vec::new();

    for msg in messages {
        match msg {
            Message::Assistant { content, .. } => {
                for block in content {
                    if let AssistantContent::ToolUse { id, .. } = block {
                        ids.push(id.as_str());
                    }
                }
            }
            Message::ToolResult { tool_call_id, .. } => {
                ids.push(tool_call_id.as_str());
            }
            Message::User { .. } => {}
        }
    }

    build_tool_call_id_mapping(&ids, IdFormat::OpenAi)
}

/// Convert a user message to chat format.
fn convert_user_message(content: &UserMessageContent, supports_images: bool) -> ChatMessage {
    match content {
        UserMessageContent::Text(text) => ChatMessage {
            role: "user".into(),
            content: Some(Value::String(text.clone())),
            tool_calls: None,
            tool_name: None,
        },
        UserMessageContent::Blocks(blocks) => {
            let parts: Vec<Value> = blocks
                .iter()
                .filter_map(|block| convert_user_block(block, supports_images))
                .collect();

            // Collapse to simple string if only text
            if parts.len() == 1
                && parts[0].get("type").and_then(Value::as_str) == Some("text")
            {
                ChatMessage {
                    role: "user".into(),
                    content: Some(parts[0]["text"].clone()),
                    tool_calls: None,
                    tool_name: None,
                }
            } else {
                ChatMessage {
                    role: "user".into(),
                    content: Some(Value::Array(parts)),
                    tool_calls: None,
                    tool_name: None,
                }
            }
        }
    }
}

/// Convert a single user content block.
fn convert_user_block(block: &UserContent, supports_images: bool) -> Option<Value> {
    match block {
        UserContent::Text { text } => Some(serde_json::json!({"type": "text", "text": text})),
        UserContent::Image { data, mime_type } => {
            if !supports_images {
                return None;
            }
            let data_uri = format!("data:{mime_type};base64,{data}");
            Some(serde_json::json!({
                "type": "image_url",
                "image_url": {"url": data_uri}
            }))
        }
        UserContent::Document {
            file_name,
            extracted_text,
            ..
        } => {
            let name = file_name.as_deref().unwrap_or("document");
            match extracted_text {
                Some(text) => Some(serde_json::json!({
                    "type": "text",
                    "text": format!("--- Document: {name} ---\n{text}")
                })),
                None => Some(serde_json::json!({
                    "type": "text",
                    "text": format!("[Document: {name} — content not available for this model]")
                })),
            }
        }
    }
}

/// Convert an assistant message to chat format.
fn convert_assistant_message(
    content: &[AssistantContent],
    id_mapping: &HashMap<String, String>,
) -> Option<ChatMessage> {
    let mut text_parts = Vec::new();
    let mut tool_calls = Vec::new();

    for block in content {
        match block {
            AssistantContent::Text { text, .. } => {
                text_parts.push(text.clone());
            }
            AssistantContent::ToolUse {
                id,
                name,
                arguments,
                ..
            } => {
                let remapped_id = remap_tool_call_id(id, id_mapping).to_string();
                tool_calls.push(ChatToolCall {
                    id: remapped_id,
                    call_type: "function".into(),
                    function: ChatFunction {
                        name: name.clone(),
                        arguments: Value::Object(arguments.clone()),
                    },
                });
            }
            // Thinking blocks are output-only, not replayed
            AssistantContent::Thinking { .. } => {}
        }
    }

    let text = if text_parts.is_empty() {
        None
    } else {
        Some(Value::String(text_parts.join("")))
    };

    let tool_calls_opt = if tool_calls.is_empty() {
        None
    } else {
        Some(tool_calls)
    };

    if text.is_none() && tool_calls_opt.is_none() {
        return None;
    }

    Some(ChatMessage {
        role: "assistant".into(),
        content: text,
        tool_calls: tool_calls_opt,
        tool_name: None,
    })
}

/// Convert a tool result to chat format.
///
/// Ollama's native `/api/chat` matches tool results to calls via `tool_name`
/// (the function name), not `tool_call_id` like OpenAI's API.
fn convert_tool_result(tool_name: &str, content: &ToolResultMessageContent) -> ChatMessage {
    let text = match content {
        ToolResultMessageContent::Text(t) => t.clone(),
        ToolResultMessageContent::Blocks(blocks) => {
            use crate::core::content::ToolResultContent;
            blocks
                .iter()
                .filter_map(|b| match b {
                    ToolResultContent::Text { text } => Some(text.clone()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
    };
    ChatMessage {
        role: "tool".into(),
        content: Some(Value::String(text)),
        tool_calls: None,
        tool_name: Some(tool_name.to_string()),
    }
}

/// Build a mapping from tool call IDs (both original and remapped) to function names.
///
/// Ollama's native API uses `tool_name` on result messages, so we need to recover
/// the function name for each `ToolResult` by scanning the preceding assistant messages.
fn build_tool_name_mapping(
    messages: &[Message],
    id_mapping: &HashMap<String, String>,
) -> HashMap<String, String> {
    let mut name_map = HashMap::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::ToolUse { id, name, .. } = block {
                    let _ = name_map.insert(id.clone(), name.clone());
                    let remapped = remap_tool_call_id(id, id_mapping);
                    if remapped != id {
                        let _ = name_map.insert(remapped.to_string(), name.clone());
                    }
                }
            }
        }
    }
    name_map
}

/// Convert Tron messages to Ollama native `/api/chat` messages.
pub fn convert_messages(messages: &[Message], supports_images: bool) -> Vec<ChatMessage> {
    let id_mapping = build_id_mapping(messages);
    let tool_name_mapping = build_tool_name_mapping(messages, &id_mapping);
    let mut result = Vec::new();

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                result.push(convert_user_message(content, supports_images));
            }
            Message::Assistant { content, .. } => {
                if let Some(msg) = convert_assistant_message(content, &id_mapping) {
                    result.push(msg);
                }
            }
            Message::ToolResult {
                tool_call_id,
                content,
                ..
            } => {
                let tool_name = tool_name_mapping
                    .get(tool_call_id.as_str())
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());
                result.push(convert_tool_result(&tool_name, content));
            }
        }
    }

    result
}

/// Convert Tron tool definitions to Ollama native API tool definitions.
pub fn convert_tools(tools: &[Tool]) -> Vec<ChatToolDef> {
    tools
        .iter()
        .map(|t| ChatToolDef {
            tool_type: "function".into(),
            function: ChatFunctionDef {
                name: t.name.clone(),
                description: t.description.clone(),
                parameters: serde_json::to_value(&t.parameters).unwrap_or_default(),
            },
        })
        .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn convert_simple_text_user_message() {
        let messages = vec![Message::user("Hello")];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "user");
        assert_eq!(result[0].content, Some(Value::String("Hello".into())));
    }

    #[test]
    fn convert_assistant_with_text() {
        let messages = vec![Message::assistant("Hi there")];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "assistant");
        assert_eq!(result[0].content, Some(Value::String("Hi there".into())));
        assert!(result[0].tool_calls.is_none());
    }

    #[test]
    fn convert_assistant_with_tool_calls() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("path".into(), json!("/tmp/test"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "toolu_abc123".into(),
                name: "read_file".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "assistant");
        let tc = result[0].tool_calls.as_ref().unwrap();
        assert_eq!(tc.len(), 1);
        assert_eq!(tc[0].function.name, "read_file");
        assert!(tc[0].id.starts_with("call_"));
        // Native Ollama API: arguments must be a JSON object, not a string
        assert_eq!(tc[0].function.arguments, json!({"path": "/tmp/test"}));
    }

    #[test]
    fn convert_assistant_thinking_blocks_skipped() {
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::Thinking {
                    thinking: "Let me think...".into(),
                    signature: None,
                },
                AssistantContent::text("The answer is 42"),
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert_eq!(
            result[0].content,
            Some(Value::String("The answer is 42".into()))
        );
    }

    #[test]
    fn convert_empty_assistant_skipped() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::Thinking {
                thinking: "hmm".into(),
                signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 0);
    }

    #[test]
    fn convert_tool_result_message() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_xyz".into(),
                    name: "bash".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_xyz".into(),
                content: ToolResultMessageContent::Text("command output".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 2);
        assert_eq!(result[1].role, "tool");
        assert_eq!(
            result[1].content,
            Some(Value::String("command output".into()))
        );
        // Native Ollama API: tool results use tool_name, not tool_call_id
        assert_eq!(result[1].tool_name, Some("bash".into()));
    }

    #[test]
    fn convert_tools_to_chat_format() {
        let tools = vec![Tool {
            name: "get_weather".into(),
            description: "Get weather info".into(),
            parameters: serde_json::from_value(json!({
                "type": "object",
                "properties": {
                    "location": {"type": "string"}
                },
                "required": ["location"]
            }))
            .unwrap(),
        }];
        let result = convert_tools(&tools);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].tool_type, "function");
        assert_eq!(result[0].function.name, "get_weather");
        assert_eq!(result[0].function.description, "Get weather info");
    }

    #[test]
    fn convert_document_with_text() {
        let block = UserContent::Document {
            file_name: Some("readme.md".into()),
            data: String::new(),
            mime_type: "text/markdown".into(),
            extracted_text: Some("# Hello".into()),
        };
        let v = convert_user_block(&block, true).unwrap();
        assert_eq!(v["type"], "text");
        assert!(v["text"].as_str().unwrap().contains("readme.md"));
        assert!(v["text"].as_str().unwrap().contains("# Hello"));
    }

    #[test]
    fn convert_document_without_text() {
        let block = UserContent::Document {
            file_name: Some("data.pdf".into()),
            data: String::new(),
            mime_type: "application/pdf".into(),
            extracted_text: None,
        };
        let v = convert_user_block(&block, true).unwrap();
        assert!(v["text"]
            .as_str()
            .unwrap()
            .contains("content not available"));
    }

    #[test]
    fn image_block_skipped_when_not_supported() {
        let block = UserContent::Image {
            data: "base64data".into(),
            mime_type: "image/png".into(),
        };
        assert!(convert_user_block(&block, false).is_none());
    }

    #[test]
    fn image_block_converted_when_supported() {
        let block = UserContent::Image {
            data: "base64data".into(),
            mime_type: "image/png".into(),
        };
        let v = convert_user_block(&block, true).unwrap();
        assert_eq!(v["type"], "image_url");
        assert!(v["image_url"]["url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,"));
    }

    #[test]
    fn mixed_text_and_tool_calls_preserved() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("q".into(), json!("test"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::text("Let me search for that."),
                AssistantContent::ToolUse {
                    id: "toolu_1".into(),
                    name: "search".into(),
                    arguments: args,
                    thought_signature: None,
                },
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert!(result[0].content.is_some());
        assert!(result[0].tool_calls.is_some());
        assert_eq!(result[0].tool_calls.as_ref().unwrap().len(), 1);
    }

    // ── Phase 1: Arguments serialize as JSON objects ─────────────────────

    #[test]
    fn tool_call_arguments_serialize_as_object() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), json!("echo hello"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "toolu_01".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);

        // Serialize the whole message to JSON and verify arguments is an object
        let wire = serde_json::to_value(&result[0]).unwrap();
        let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
        assert!(wire_args.is_object(), "arguments must be a JSON object on the wire, got: {wire_args}");
        assert_eq!(wire_args["command"], "echo hello");
    }

    #[test]
    fn tool_call_empty_arguments_serialize_as_object() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "toolu_01".into(),
                name: "bash".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(wire_args.as_object().unwrap().len(), 0);
    }

    #[test]
    fn tool_call_nested_arguments_serialize_as_object() {
        let mut args = serde_json::Map::new();
        let _ = args.insert(
            "config".into(),
            json!({"key": "value", "nested": {"deep": true}}),
        );
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_abc".into(),
                name: "configure".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(wire_args["config"]["nested"]["deep"], true);
    }

    #[test]
    fn tool_call_arguments_with_special_chars() {
        let mut args = serde_json::Map::new();
        let _ = args.insert(
            "command".into(),
            json!("echo \"hello\\nworld\" | grep 'test'"),
        );
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "toolu_01".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(
            wire_args["command"],
            "echo \"hello\\nworld\" | grep 'test'"
        );
    }

    #[test]
    fn multiple_tool_calls_arguments_all_objects() {
        let mut args1 = serde_json::Map::new();
        let _ = args1.insert("path".into(), json!("/tmp/a"));
        let mut args2 = serde_json::Map::new();
        let _ = args2.insert("path".into(), json!("/tmp/b"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::ToolUse {
                    id: "toolu_01".into(),
                    name: "read".into(),
                    arguments: args1,
                    thought_signature: None,
                },
                AssistantContent::ToolUse {
                    id: "toolu_02".into(),
                    name: "read".into(),
                    arguments: args2,
                    thought_signature: None,
                },
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        for (i, tc) in wire["tool_calls"].as_array().unwrap().iter().enumerate() {
            assert!(
                tc["function"]["arguments"].is_object(),
                "tool_call[{i}] arguments must be a JSON object"
            );
        }
    }

    // ── Phase 2: Tool results use tool_name ─────────────────────────────

    #[test]
    fn tool_result_has_tool_name() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01".into(),
                    name: "bash".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_01".into(),
                content: ToolResultMessageContent::Text("ok".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[1]).unwrap();
        assert_eq!(wire["tool_name"], "bash");
        assert!(wire.get("tool_call_id").is_none());
    }

    #[test]
    fn tool_result_after_provider_switch() {
        // Anthropic-origin IDs (toolu_*) must still resolve to tool_name
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01abc".into(),
                    name: "read_file".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_01abc".into(),
                content: ToolResultMessageContent::Text("file contents".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].tool_name, Some("read_file".into()));
    }

    #[test]
    fn tool_result_with_blocks_content() {
        use crate::core::content::ToolResultContent;
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_abc".into(),
                    name: "search".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "call_abc".into(),
                content: ToolResultMessageContent::Blocks(vec![
                    ToolResultContent::text("line1"),
                    ToolResultContent::text("line2"),
                ]),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].tool_name, Some("search".into()));
        assert_eq!(
            result[1].content,
            Some(Value::String("line1\nline2".into()))
        );
    }

    #[test]
    fn tool_result_with_is_error_still_converts() {
        // is_error is silently dropped (Ollama native API doesn't support it)
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_err".into(),
                    name: "bash".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_err".into(),
                content: ToolResultMessageContent::Text("Error: permission denied".into()),
                is_error: Some(true),
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].role, "tool");
        assert_eq!(result[1].tool_name, Some("bash".into()));
        assert_eq!(
            result[1].content,
            Some(Value::String("Error: permission denied".into()))
        );
    }

    #[test]
    fn full_roundtrip_conversation() {
        // Full conversation: user → assistant+tool_call → tool_result
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), json!("echo hello"));
        let messages = vec![
            Message::user("Run a command for me"),
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01".into(),
                    name: "bash".into(),
                    arguments: args,
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_01".into(),
                content: ToolResultMessageContent::Text("hello".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 3);

        // Serialize full conversation to verify wire format
        let wire: Vec<Value> = result.iter().map(|m| serde_json::to_value(m).unwrap()).collect();

        // User message
        assert_eq!(wire[0]["role"], "user");

        // Assistant message with tool call — arguments is an object
        assert_eq!(wire[1]["role"], "assistant");
        assert!(wire[1]["tool_calls"][0]["function"]["arguments"].is_object());
        assert_eq!(
            wire[1]["tool_calls"][0]["function"]["arguments"]["command"],
            "echo hello"
        );

        // Tool result — uses tool_name, no tool_call_id
        assert_eq!(wire[2]["role"], "tool");
        assert_eq!(wire[2]["tool_name"], "bash");
        assert_eq!(wire[2]["content"], "hello");
        assert!(wire[2].get("tool_call_id").is_none());
    }

    #[test]
    fn multiple_tool_calls_multiple_results() {
        let mut args1 = serde_json::Map::new();
        let _ = args1.insert("path".into(), json!("/a"));
        let mut args2 = serde_json::Map::new();
        let _ = args2.insert("command".into(), json!("ls"));
        let messages = vec![
            Message::Assistant {
                content: vec![
                    AssistantContent::ToolUse {
                        id: "toolu_01".into(),
                        name: "read_file".into(),
                        arguments: args1,
                        thought_signature: None,
                    },
                    AssistantContent::ToolUse {
                        id: "toolu_02".into(),
                        name: "bash".into(),
                        arguments: args2,
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_01".into(),
                content: ToolResultMessageContent::Text("file contents".into()),
                is_error: None,
            },
            Message::ToolResult {
                tool_call_id: "toolu_02".into(),
                content: ToolResultMessageContent::Text("dir listing".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 3);
        assert_eq!(result[1].tool_name, Some("read_file".into()));
        assert_eq!(result[2].tool_name, Some("bash".into()));
    }

    #[test]
    fn tool_result_orphaned_id_fallback() {
        // ToolResult with no matching assistant tool call → fallback to "unknown"
        let messages = vec![Message::ToolResult {
            tool_call_id: "orphan_id".into(),
            content: ToolResultMessageContent::Text("result".into()),
            is_error: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result[0].tool_name, Some("unknown".into()));
    }

    // ── Phase 3: Edge case verification ─────────────────────────────────

    #[test]
    fn assistant_only_tool_calls_no_text() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_abc".into(),
                name: "bash".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert!(result[0].content.is_none());
        assert!(result[0].tool_calls.is_some());
    }

    #[test]
    fn assistant_thinking_text_and_tool_calls() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("q".into(), json!("rust"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::Thinking {
                    thinking: "Let me plan this...".into(),
                    signature: None,
                },
                AssistantContent::text("I'll search for that."),
                AssistantContent::ToolUse {
                    id: "toolu_01".into(),
                    name: "search".into(),
                    arguments: args,
                    thought_signature: None,
                },
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        // Thinking is dropped
        assert_eq!(
            result[0].content,
            Some(Value::String("I'll search for that.".into()))
        );
        // Tool call preserved with object arguments
        let tc = result[0].tool_calls.as_ref().unwrap();
        assert_eq!(tc[0].function.name, "search");
        assert_eq!(tc[0].function.arguments, json!({"q": "rust"}));
    }

    #[test]
    fn tool_call_id_already_openai_format() {
        // IDs already in OpenAI format → no remapping needed, tool_name still resolves
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_already_openai".into(),
                    name: "bash".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "call_already_openai".into(),
                content: ToolResultMessageContent::Text("done".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        // ID passed through unchanged
        assert_eq!(
            result[0].tool_calls.as_ref().unwrap()[0].id,
            "call_already_openai"
        );
        // tool_name still resolved correctly
        assert_eq!(result[1].tool_name, Some("bash".into()));
    }
}
