//! Message format conversion: Tron messages → OpenAI chat completions format.
//!
//! Ollama uses the same OpenAI-compatible chat completions format as Kimi.
//! This module converts Tron's internal message types to the wire format.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::core::content::{AssistantContent, UserContent};
use crate::core::messages::{Message, ToolResultMessageContent, UserMessageContent};
use crate::core::tools::Tool;
use crate::llm::id_remapping::{IdFormat, build_tool_call_id_mapping, remap_tool_call_id};

// ─── Wire types ──────────────────────────────────────────────────────────────

/// A chat completion message in OpenAI format.
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
    /// Tool call ID (for tool result messages).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// A tool call in OpenAI format.
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
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatFunction {
    /// Function name.
    pub name: String,
    /// JSON-encoded arguments string.
    pub arguments: String,
}

/// Tool definition in OpenAI format.
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
            tool_call_id: None,
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
                let args_str =
                    serde_json::to_string(&Value::Object(arguments.clone())).unwrap_or_default();
                tool_calls.push(ChatToolCall {
                    id: remapped_id,
                    call_type: "function".into(),
                    function: ChatFunction {
                        name: name.clone(),
                        arguments: args_str,
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
        tool_call_id: None,
    })
}

/// Convert a tool result to chat format.
fn convert_tool_result(tool_call_id: &str, content: &ToolResultMessageContent) -> ChatMessage {
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
        tool_call_id: Some(tool_call_id.to_string()),
    }
}

/// Convert Tron messages to OpenAI chat completion messages.
pub fn convert_messages(messages: &[Message], supports_images: bool) -> Vec<ChatMessage> {
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

/// Convert Tron tool definitions to OpenAI chat completion tool definitions.
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
        let parsed: serde_json::Value = serde_json::from_str(&tc[0].function.arguments).unwrap();
        assert_eq!(parsed["path"], "/tmp/test");
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
        assert!(result[1].tool_call_id.is_some());
        // Tool call IDs should match (both remapped from toolu_ to call_)
        let tc_id = &result[0].tool_calls.as_ref().unwrap()[0].id;
        let result_id = result[1].tool_call_id.as_ref().unwrap();
        assert_eq!(tc_id, result_id);
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
}
