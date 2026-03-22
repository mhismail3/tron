//! Kimi message converter — `Context` → OpenAI chat completions format.
//!
//! Converts Tron's internal message types to the chat completions `messages`
//! array format used by Kimi's API (`POST /v1/chat/completions`).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::core::content::{AssistantContent, UserContent};
use crate::core::messages::{
    Message, ToolResultMessageContent, UserMessageContent,
};
use crate::core::tools::Tool;
use crate::llm::id_remapping::{IdFormat, build_tool_call_id_mapping, remap_tool_call_id};


/// A single message in OpenAI chat completions format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatMessage {
    /// Role: `"system"`, `"user"`, `"assistant"`, or `"tool"`.
    pub role: String,
    /// Text content (mutually exclusive with structured content).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    /// Tool calls made by the assistant.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ChatToolCall>>,
    /// Tool call ID (only for role=tool).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// A tool call in chat completions format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatToolCall {
    /// Tool call ID.
    pub id: String,
    /// Always `"function"`.
    #[serde(rename = "type")]
    pub call_type: String,
    /// Function details.
    pub function: ChatFunction,
}

/// Function details within a tool call.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatFunction {
    /// Function name.
    pub name: String,
    /// JSON-encoded arguments string.
    pub arguments: String,
}

/// A tool definition in chat completions format.
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
    /// Function description.
    pub description: String,
    /// JSON Schema for parameters.
    pub parameters: Value,
}

/// Convert Tron messages to OpenAI chat completions format.
///
/// Handles ID remapping from Anthropic `toolu_` format to OpenAI `call_` format.
/// Strips image content blocks when `supports_images` is `false`.
/// Omits thinking blocks from assistant messages (thinking is output-only).
pub fn convert_messages(
    messages: &[Message],
    supports_images: bool,
) -> Vec<ChatMessage> {
    let id_mapping = build_id_mapping(messages);
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
                let remapped_id = remap_tool_call_id(tool_call_id, &id_mapping).to_string();
                result.push(convert_tool_result(&remapped_id, content));
            }
        }
    }

    result
}

/// Convert tool definitions to chat completions format.
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

// ─── Internal helpers ──────────────────────────────────────────────────────

/// Build ID mapping for tool calls that need format conversion.
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
            _ => {}
        }
    }

    build_tool_call_id_mapping(&ids, IdFormat::OpenAi)
}

fn convert_user_message(content: &UserMessageContent, supports_images: bool) -> ChatMessage {
    match content {
        UserMessageContent::Text(text) => ChatMessage {
            role: "user".into(),
            content: Some(Value::String(text.clone())),
            tool_calls: None,
            tool_call_id: None,
        },
        UserMessageContent::Blocks(blocks) => {
            let parts: Vec<Value> = blocks
                .iter()
                .filter_map(|block| convert_user_block(block, supports_images))
                .collect();

            if parts.len() == 1 && parts[0].get("type").and_then(Value::as_str) == Some("text") {
                ChatMessage {
                    role: "user".into(),
                    content: Some(parts[0]["text"].clone()),
                    tool_calls: None,
                    tool_call_id: None,
                }
            } else if parts.is_empty() {
                ChatMessage {
                    role: "user".into(),
                    content: Some(Value::String(String::new())),
                    tool_calls: None,
                    tool_call_id: None,
                }
            } else {
                ChatMessage {
                    role: "user".into(),
                    content: Some(Value::Array(parts)),
                    tool_calls: None,
                    tool_call_id: None,
                }
            }
        }
    }
}

fn convert_user_block(block: &UserContent, supports_images: bool) -> Option<Value> {
    match block {
        UserContent::Text { text } => Some(json!({"type": "text", "text": text})),
        UserContent::Image { data, mime_type } => {
            if !supports_images {
                return None;
            }
            let data_uri = format!("data:{mime_type};base64,{data}");
            Some(json!({
                "type": "image_url",
                "image_url": {"url": data_uri}
            }))
        }
        UserContent::Document { file_name, .. } => {
            let name = file_name.as_deref().unwrap_or("document");
            Some(json!({"type": "text", "text": format!("[Document: {name}]")}))
        }
    }
}

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
                let args_str = serde_json::to_string(&Value::Object(arguments.clone()))
                    .unwrap_or_default();
                tool_calls.push(ChatToolCall {
                    id: remapped_id,
                    call_type: "function".into(),
                    function: ChatFunction {
                        name: name.clone(),
                        arguments: args_str,
                    },
                });
            }
            // Skip thinking blocks — thinking is output-only, not replayed.
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
        tool_call_id: None,
    })
}

fn convert_tool_result(tool_call_id: &str, content: &ToolResultMessageContent) -> ChatMessage {
    let text = match content {
        ToolResultMessageContent::Text(t) => t.clone(),
        ToolResultMessageContent::Blocks(blocks) => {
            blocks
                .iter()
                .filter_map(|b| match b {
                    crate::core::content::ToolResultContent::Text { text } => Some(text.as_str()),
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
        tool_call_id: Some(tool_call_id.to_string()),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::content::ToolResultContent;
    use crate::core::tools::ToolParameterSchema;
    use serde_json::Map;

    #[test]
    fn user_text_message() {
        let msgs = vec![Message::user("hello")];
        let result = convert_messages(&msgs, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "user");
        assert_eq!(result[0].content.as_ref().unwrap(), "hello");
    }

    #[test]
    fn user_message_with_image() {
        let msgs = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text { text: "Look".into() },
                UserContent::Image {
                    data: "abc123".into(),
                    mime_type: "image/png".into(),
                },
            ]),
            timestamp: None,
        }];
        let result = convert_messages(&msgs, true);
        let content = result[0].content.as_ref().unwrap().as_array().unwrap();
        assert_eq!(content.len(), 2);
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[1]["type"], "image_url");
        assert!(content[1]["image_url"]["url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,"));
    }

    #[test]
    fn image_stripped_when_not_supported() {
        let msgs = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text { text: "Look".into() },
                UserContent::Image {
                    data: "abc123".into(),
                    mime_type: "image/png".into(),
                },
            ]),
            timestamp: None,
        }];
        let result = convert_messages(&msgs, false);
        // Should collapse to simple text since only text remains
        assert_eq!(result[0].content.as_ref().unwrap(), "Look");
    }

    #[test]
    fn assistant_text_message() {
        let msgs = vec![Message::assistant("world")];
        let result = convert_messages(&msgs, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "assistant");
        assert_eq!(result[0].content.as_ref().unwrap(), "world");
        assert!(result[0].tool_calls.is_none());
    }

    #[test]
    fn assistant_with_tool_calls() {
        let mut args = Map::new();
        let _ = args.insert("cmd".into(), json!("ls"));
        let msgs = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "call_abc".into(),
                name: "bash".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&msgs, true);
        assert_eq!(result[0].role, "assistant");
        let tc = result[0].tool_calls.as_ref().unwrap();
        assert_eq!(tc.len(), 1);
        assert_eq!(tc[0].id, "call_abc");
        assert_eq!(tc[0].call_type, "function");
        assert_eq!(tc[0].function.name, "bash");
        assert_eq!(tc[0].function.arguments, r#"{"cmd":"ls"}"#);
    }

    #[test]
    fn assistant_with_text_and_tool_calls() {
        let mut args = Map::new();
        let _ = args.insert("q".into(), json!("test"));
        let msgs = vec![Message::Assistant {
            content: vec![
                AssistantContent::text("Let me check"),
                AssistantContent::ToolUse {
                    id: "call_1".into(),
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
        let result = convert_messages(&msgs, true);
        assert!(result[0].content.is_some());
        assert!(result[0].tool_calls.is_some());
    }

    #[test]
    fn thinking_blocks_omitted() {
        let msgs = vec![Message::Assistant {
            content: vec![
                AssistantContent::Thinking {
                    thinking: "hmm".into(),
                    signature: None,
                },
                AssistantContent::text("result"),
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        let result = convert_messages(&msgs, true);
        assert_eq!(result[0].content.as_ref().unwrap(), "result");
    }

    #[test]
    fn tool_result_message() {
        let msgs = vec![
            // Need an assistant message first with the tool call for ID mapping
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_abc".into(),
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
                tool_call_id: "call_abc".into(),
                content: ToolResultMessageContent::Text("done".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&msgs, true);
        assert_eq!(result[1].role, "tool");
        assert_eq!(result[1].content.as_ref().unwrap(), "done");
        assert_eq!(result[1].tool_call_id.as_ref().unwrap(), "call_abc");
    }

    #[test]
    fn id_remapping_anthropic_to_openai() {
        let mut args = Map::new();
        let _ = args.insert("x".into(), json!(1));
        let msgs = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "toolu_01abc".into(),
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
                tool_call_id: "toolu_01abc".into(),
                content: ToolResultMessageContent::Text("ok".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&msgs, true);
        // Anthropic IDs should be remapped to call_ format
        let tc = &result[0].tool_calls.as_ref().unwrap()[0];
        assert!(tc.id.starts_with("call_"), "Expected call_ prefix, got: {}", tc.id);
        assert_eq!(result[1].tool_call_id.as_ref().unwrap(), &tc.id);
    }

    #[test]
    fn empty_messages() {
        let result = convert_messages(&[], true);
        assert!(result.is_empty());
    }

    #[test]
    fn multi_turn_ordering() {
        let msgs = vec![
            Message::user("hello"),
            Message::assistant("hi"),
            Message::user("bye"),
        ];
        let result = convert_messages(&msgs, true);
        assert_eq!(result.len(), 3);
        assert_eq!(result[0].role, "user");
        assert_eq!(result[1].role, "assistant");
        assert_eq!(result[2].role, "user");
    }

    #[test]
    fn convert_tools_format() {
        let tools = vec![Tool {
            name: "bash".into(),
            description: "Run commands".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: None,
                required: None,
                description: None,
                extra: serde_json::Map::default(),
            },
        }];
        let result = convert_tools(&tools);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].tool_type, "function");
        assert_eq!(result[0].function.name, "bash");
        assert_eq!(result[0].function.description, "Run commands");
    }

    #[test]
    fn document_in_user_message() {
        let msgs = vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::Document {
                data: "base64data".into(),
                mime_type: "text/plain".into(),
                file_name: Some("file.rs".into()),
            }]),
            timestamp: None,
        }];
        let result = convert_messages(&msgs, true);
        let text = result[0].content.as_ref().unwrap().as_str().unwrap();
        assert!(text.contains("file.rs"));
    }

    #[test]
    fn tool_result_blocks() {
        let msgs = vec![
            Message::Assistant {
                content: vec![AssistantContent::ToolUse {
                    id: "call_1".into(),
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
                tool_call_id: "call_1".into(),
                content: ToolResultMessageContent::Blocks(vec![
                    ToolResultContent::text("line1"),
                    ToolResultContent::text("line2"),
                ]),
                is_error: None,
            },
        ];
        let result = convert_messages(&msgs, true);
        assert_eq!(result[1].content.as_ref().unwrap(), "line1\nline2");
    }
}
