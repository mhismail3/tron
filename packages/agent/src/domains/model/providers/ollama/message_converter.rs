//! Message format conversion: Tron messages → Ollama native `/api/chat` format.
//!
//! Ollama's native API is similar to OpenAI chat completions but differs in two
//! key ways for capability invocationing:
//!
//! - **Capability invocation arguments** are JSON objects, not JSON-encoded strings.
//! - **Capability result messages** use `model_primitive_name` (function name) instead of `invocation_id`.
//!
//! This module converts Tron's internal message types to the native wire format.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domains::model::providers::id_remapping::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::content::{AssistantContent, UserContent};
use crate::shared::messages::{CapabilityResultMessageContent, Message, UserMessageContent};
use crate::shared::model_capabilities::ModelCapability;

// ─── Wire types ──────────────────────────────────────────────────────────────

/// A chat message in Ollama's native `/api/chat` format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatMessage {
    /// Message role: `"system"`, `"user"`, `"assistant"`, or `"tool"`.
    pub role: String,
    /// Text content for Ollama's native `/api/chat` endpoint.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// Base64-encoded image payloads for multimodal Ollama models.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<String>>,
    /// Capability invocations made by the assistant.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_invocations: Option<Vec<ChatCapabilityInvocationDraft>>,
    /// Capability name (for capability result messages).
    ///
    /// Ollama's native `/api/chat` uses `model_primitive_name` (the function name) to match
    /// results to calls, not `invocation_id` like OpenAI's API.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_primitive_name: Option<String>,
}

/// A capability invocation in Ollama's native format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatCapabilityInvocationDraft {
    /// Unique capability invocation ID.
    pub id: String,
    /// Always `"function"`.
    #[serde(rename = "type")]
    pub call_type: String,
    /// Function name and arguments.
    pub function: ChatFunction,
}

/// Function name + arguments in a capability invocation.
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

/// ModelCapability definition for Ollama's native API.
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

/// Build a capability invocation ID mapping for all messages (Anthropic → OpenAI format).
fn build_id_mapping(messages: &[Message]) -> HashMap<String, String> {
    let mut ids = Vec::new();

    for msg in messages {
        match msg {
            Message::Assistant { content, .. } => {
                for block in content {
                    if let AssistantContent::CapabilityInvocation { id, .. } = block {
                        ids.push(id.as_str());
                    }
                }
            }
            Message::CapabilityResult { invocation_id, .. } => {
                ids.push(invocation_id.as_str());
            }
            Message::User { .. } => {}
        }
    }

    build_invocation_id_mapping(&ids, IdFormat::OpenAi)
}

/// Convert a user message to chat format.
fn convert_user_message(content: &UserMessageContent, supports_images: bool) -> ChatMessage {
    match content {
        UserMessageContent::Text(text) => ChatMessage {
            role: "user".into(),
            content: Some(text.clone()),
            images: None,
            capability_invocations: None,
            model_primitive_name: None,
        },
        UserMessageContent::Blocks(blocks) => {
            let mut text_parts = Vec::new();
            let mut images = Vec::new();
            for block in blocks {
                match convert_user_block(block, supports_images) {
                    ConvertedUserBlock::Text(text) => text_parts.push(text),
                    ConvertedUserBlock::Image(data) => images.push(data),
                    ConvertedUserBlock::None => {}
                }
            }

            ChatMessage {
                role: "user".into(),
                content: Some(text_parts.join("\n\n")),
                images: (!images.is_empty()).then_some(images),
                capability_invocations: None,
                model_primitive_name: None,
            }
        }
    }
}

enum ConvertedUserBlock {
    Text(String),
    Image(String),
    None,
}

/// Convert a single user content block.
fn convert_user_block(block: &UserContent, supports_images: bool) -> ConvertedUserBlock {
    match block {
        UserContent::Text { text } => ConvertedUserBlock::Text(text.clone()),
        UserContent::Image { data, mime_type: _ } => {
            if !supports_images {
                return ConvertedUserBlock::None;
            }
            ConvertedUserBlock::Image(data.clone())
        }
        UserContent::Document {
            file_name,
            extracted_text,
            ..
        } => {
            let name = file_name.as_deref().unwrap_or("document");
            match extracted_text {
                Some(text) => ConvertedUserBlock::Text(format!("--- Document: {name} ---\n{text}")),
                None => ConvertedUserBlock::Text(format!(
                    "[Document: {name} — content not available for this model]"
                )),
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
    let mut capability_invocations = Vec::new();

    for block in content {
        match block {
            AssistantContent::Text { text, .. } => {
                text_parts.push(text.clone());
            }
            AssistantContent::CapabilityInvocation {
                id,
                name,
                arguments,
                ..
            } => {
                let remapped_id = remap_invocation_id(id, id_mapping).to_string();
                capability_invocations.push(ChatCapabilityInvocationDraft {
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
        Some(text_parts.join(""))
    };

    let capability_invocations_opt = if capability_invocations.is_empty() {
        None
    } else {
        Some(capability_invocations)
    };

    if text.is_none() && capability_invocations_opt.is_none() {
        return None;
    }

    Some(ChatMessage {
        role: "assistant".into(),
        content: text,
        images: None,
        capability_invocations: capability_invocations_opt,
        model_primitive_name: None,
    })
}

/// Convert a capability result to chat format.
///
/// Ollama's native `/api/chat` matches capability results to calls via `model_primitive_name`
/// (the function name), not `invocation_id` like OpenAI's API.
fn convert_capability_result(
    model_primitive_name: &str,
    content: &CapabilityResultMessageContent,
) -> ChatMessage {
    let text = match content {
        CapabilityResultMessageContent::Text(t) => t.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => {
            use crate::shared::content::CapabilityResultContent;
            blocks
                .iter()
                .filter_map(|b| match b {
                    CapabilityResultContent::Text { text } => Some(text.clone()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("\n")
        }
    };
    ChatMessage {
        role: "tool".into(),
        content: Some(text),
        images: None,
        capability_invocations: None,
        model_primitive_name: Some(model_primitive_name.to_string()),
    }
}

/// Build a mapping from capability invocation IDs (both original and remapped) to function names.
///
/// Ollama's native API uses `model_primitive_name` on result messages, so we need to recover
/// the function name for each `ToolResult` by scanning the preceding assistant messages.
fn build_model_primitive_name_mapping(
    messages: &[Message],
    id_mapping: &HashMap<String, String>,
) -> HashMap<String, String> {
    let mut name_map = HashMap::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::CapabilityInvocation { id, name, .. } = block {
                    let _ = name_map.insert(id.clone(), name.clone());
                    let remapped = remap_invocation_id(id, id_mapping);
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
    let model_primitive_name_mapping = build_model_primitive_name_mapping(messages, &id_mapping);
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
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                let model_primitive_name = model_primitive_name_mapping
                    .get(invocation_id.as_str())
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());
                result.push(convert_capability_result(&model_primitive_name, content));
            }
        }
    }

    result
}

/// Convert Tron tool definitions to Ollama native API tool definitions.
pub fn convert_tools(capabilities: &[ModelCapability]) -> Vec<ChatToolDef> {
    capabilities
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
        assert_eq!(result[0].content, Some("Hello".into()));
    }

    #[test]
    fn multi_block_user_message_serializes_native_content_as_string() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text {
                    text: "Compacted summary".into(),
                },
                UserContent::Document {
                    file_name: Some("scorecard.md".into()),
                    data: String::new(),
                    mime_type: "text/markdown".into(),
                    extracted_text: Some("Scenario evidence".into()),
                },
            ]),
            timestamp: None,
        }];

        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        assert!(
            wire["content"].is_string(),
            "Ollama content must be a string"
        );
        assert!(
            wire["content"]
                .as_str()
                .unwrap()
                .contains("Compacted summary")
        );
        assert!(wire["content"].as_str().unwrap().contains("scorecard.md"));
        assert!(wire.get("images").is_none());
    }

    #[test]
    fn image_user_message_uses_native_images_field() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text {
                    text: "Describe this image".into(),
                },
                UserContent::Image {
                    data: "base64data".into(),
                    mime_type: "image/png".into(),
                },
            ]),
            timestamp: None,
        }];

        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[0]).unwrap();
        assert_eq!(wire["content"], "Describe this image");
        assert_eq!(wire["images"][0], "base64data");
    }

    #[test]
    fn convert_assistant_with_text() {
        let messages = vec![Message::assistant("Hi there")];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].role, "assistant");
        assert_eq!(result[0].content, Some("Hi there".into()));
        assert!(result[0].capability_invocations.is_none());
    }

    #[test]
    fn convert_assistant_with_capability_invocations() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("path".into(), json!("/tmp/test"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
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
        let tc = result[0].capability_invocations.as_ref().unwrap();
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
        assert_eq!(result[0].content, Some("The answer is 42".into()));
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
    fn convert_capability_result_message() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "toolu_xyz".into(),
                    name: "execute".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_xyz".into(),
                content: CapabilityResultMessageContent::Text("command output".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 2);
        assert_eq!(result[1].role, "tool");
        assert_eq!(result[1].content, Some("command output".into()));
        // Native Ollama API: capability results use model_primitive_name, not invocation_id
        assert_eq!(result[1].model_primitive_name, Some("execute".into()));
    }

    #[test]
    fn convert_tools_to_chat_format() {
        let capabilities = vec![ModelCapability {
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
        let result = convert_tools(&capabilities);
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
        let ConvertedUserBlock::Text(text) = convert_user_block(&block, true) else {
            panic!("document should flatten to text");
        };
        assert!(text.contains("readme.md"));
        assert!(text.contains("# Hello"));
    }

    #[test]
    fn convert_document_without_text() {
        let block = UserContent::Document {
            file_name: Some("data.pdf".into()),
            data: String::new(),
            mime_type: "application/pdf".into(),
            extracted_text: None,
        };
        let ConvertedUserBlock::Text(text) = convert_user_block(&block, true) else {
            panic!("document should flatten to text");
        };
        assert!(text.contains("content not available"));
    }

    #[test]
    fn image_block_skipped_when_not_supported() {
        let block = UserContent::Image {
            data: "base64data".into(),
            mime_type: "image/png".into(),
        };
        assert!(matches!(
            convert_user_block(&block, false),
            ConvertedUserBlock::None
        ));
    }

    #[test]
    fn image_block_converted_when_supported() {
        let block = UserContent::Image {
            data: "base64data".into(),
            mime_type: "image/png".into(),
        };
        let ConvertedUserBlock::Image(data) = convert_user_block(&block, true) else {
            panic!("image should convert to native Ollama image bytes");
        };
        assert_eq!(data, "base64data");
    }

    #[test]
    fn mixed_text_and_capability_invocations_preserved() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("q".into(), json!("test"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::text("Let me search for that."),
                AssistantContent::CapabilityInvocation {
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
        assert!(result[0].capability_invocations.is_some());
        assert_eq!(result[0].capability_invocations.as_ref().unwrap().len(), 1);
    }

    // ── Phase 1: Arguments serialize as JSON objects ─────────────────────

    #[test]
    fn capability_invocation_arguments_serialize_as_object() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), json!("echo hello"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "execute".into(),
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
        let wire_args = &wire["capability_invocations"][0]["function"]["arguments"];
        assert!(
            wire_args.is_object(),
            "arguments must be a JSON object on the wire, got: {wire_args}"
        );
        assert_eq!(wire_args["command"], "echo hello");
    }

    #[test]
    fn capability_invocation_empty_arguments_serialize_as_object() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "execute".into(),
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
        let wire_args = &wire["capability_invocations"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(wire_args.as_object().unwrap().len(), 0);
    }

    #[test]
    fn capability_invocation_nested_arguments_serialize_as_object() {
        let mut args = serde_json::Map::new();
        let _ = args.insert(
            "config".into(),
            json!({"key": "value", "nested": {"deep": true}}),
        );
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
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
        let wire_args = &wire["capability_invocations"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(wire_args["config"]["nested"]["deep"], true);
    }

    #[test]
    fn capability_invocation_arguments_with_special_chars() {
        let mut args = serde_json::Map::new();
        let _ = args.insert(
            "command".into(),
            json!("echo \"hello\\nworld\" | grep 'test'"),
        );
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "execute".into(),
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
        let wire_args = &wire["capability_invocations"][0]["function"]["arguments"];
        assert!(wire_args.is_object());
        assert_eq!(wire_args["command"], "echo \"hello\\nworld\" | grep 'test'");
    }

    #[test]
    fn multiple_capability_invocations_arguments_all_objects() {
        let mut args1 = serde_json::Map::new();
        let _ = args1.insert("path".into(), json!("/tmp/a"));
        let mut args2 = serde_json::Map::new();
        let _ = args2.insert("path".into(), json!("/tmp/b"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::CapabilityInvocation {
                    id: "toolu_01".into(),
                    name: "inspect".into(),
                    arguments: args1,
                    thought_signature: None,
                },
                AssistantContent::CapabilityInvocation {
                    id: "toolu_02".into(),
                    name: "inspect".into(),
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
        for (i, tc) in wire["capability_invocations"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
        {
            assert!(
                tc["function"]["arguments"].is_object(),
                "capability_invocation[{i}] arguments must be a JSON object"
            );
        }
    }

    // ── Phase 2: Capability results use model_primitive_name ─────────────────────────────

    #[test]
    fn capability_result_has_model_primitive_name() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "toolu_01".into(),
                    name: "execute".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_01".into(),
                content: CapabilityResultMessageContent::Text("ok".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        let wire = serde_json::to_value(&result[1]).unwrap();
        assert_eq!(wire["model_primitive_name"], "execute");
        assert!(wire.get("invocation_id").is_none());
    }

    #[test]
    fn capability_result_after_provider_switch() {
        // Anthropic-origin IDs (toolu_*) must still resolve to model_primitive_name
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
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
            Message::CapabilityResult {
                invocation_id: "toolu_01abc".into(),
                content: CapabilityResultMessageContent::Text("file contents".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].model_primitive_name, Some("read_file".into()));
    }

    #[test]
    fn capability_result_with_blocks_content() {
        use crate::shared::content::CapabilityResultContent;
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
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
            Message::CapabilityResult {
                invocation_id: "call_abc".into(),
                content: CapabilityResultMessageContent::Blocks(vec![
                    CapabilityResultContent::text("line1"),
                    CapabilityResultContent::text("line2"),
                ]),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].model_primitive_name, Some("search".into()));
        assert_eq!(result[1].content, Some("line1\nline2".into()));
    }

    #[test]
    fn capability_result_with_is_error_still_converts() {
        // is_error is silently dropped (Ollama native API doesn't support it)
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "toolu_err".into(),
                    name: "execute".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_err".into(),
                content: CapabilityResultMessageContent::Text("Error: permission denied".into()),
                is_error: Some(true),
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result[1].role, "tool");
        assert_eq!(result[1].model_primitive_name, Some("execute".into()));
        assert_eq!(result[1].content, Some("Error: permission denied".into()));
    }

    #[test]
    fn full_roundtrip_conversation() {
        // Full conversation: user → assistant+capability_invocation → capability_result
        let mut args = serde_json::Map::new();
        let _ = args.insert("command".into(), json!("echo hello"));
        let messages = vec![
            Message::user("Run a command for me"),
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "toolu_01".into(),
                    name: "execute".into(),
                    arguments: args,
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_01".into(),
                content: CapabilityResultMessageContent::Text("hello".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 3);

        // Serialize full conversation to verify wire format
        let wire: Vec<Value> = result
            .iter()
            .map(|m| serde_json::to_value(m).unwrap())
            .collect();

        // User message
        assert_eq!(wire[0]["role"], "user");

        // Assistant message with capability invocation — arguments is an object
        assert_eq!(wire[1]["role"], "assistant");
        assert!(wire[1]["capability_invocations"][0]["function"]["arguments"].is_object());
        assert_eq!(
            wire[1]["capability_invocations"][0]["function"]["arguments"]["command"],
            "echo hello"
        );

        // Capability result — uses model_primitive_name, no invocation_id
        assert_eq!(wire[2]["role"], "tool");
        assert_eq!(wire[2]["model_primitive_name"], "execute");
        assert_eq!(wire[2]["content"], "hello");
        assert!(wire[2].get("invocation_id").is_none());
    }

    #[test]
    fn multiple_capability_invocations_multiple_results() {
        let mut args1 = serde_json::Map::new();
        let _ = args1.insert("path".into(), json!("/a"));
        let mut args2 = serde_json::Map::new();
        let _ = args2.insert("command".into(), json!("ls"));
        let messages = vec![
            Message::Assistant {
                content: vec![
                    AssistantContent::CapabilityInvocation {
                        id: "toolu_01".into(),
                        name: "read_file".into(),
                        arguments: args1,
                        thought_signature: None,
                    },
                    AssistantContent::CapabilityInvocation {
                        id: "toolu_02".into(),
                        name: "execute".into(),
                        arguments: args2,
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_01".into(),
                content: CapabilityResultMessageContent::Text("file contents".into()),
                is_error: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_02".into(),
                content: CapabilityResultMessageContent::Text("dir listing".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        assert_eq!(result.len(), 3);
        assert_eq!(result[1].model_primitive_name, Some("read_file".into()));
        assert_eq!(result[2].model_primitive_name, Some("execute".into()));
    }

    #[test]
    fn capability_result_orphaned_id_unknown_marker() {
        // ToolResult with no matching assistant capability invocation → mark as "unknown".
        let messages = vec![Message::CapabilityResult {
            invocation_id: "orphan_id".into(),
            content: CapabilityResultMessageContent::Text("result".into()),
            is_error: None,
        }];
        let result = convert_messages(&messages, true);
        assert_eq!(result[0].model_primitive_name, Some("unknown".into()));
    }

    // ── Phase 3: Edge case verification ─────────────────────────────────

    #[test]
    fn assistant_only_capability_invocations_no_text() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_abc".into(),
                name: "execute".into(),
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
        assert!(result[0].capability_invocations.is_some());
    }

    #[test]
    fn assistant_thinking_text_and_capability_invocations() {
        let mut args = serde_json::Map::new();
        let _ = args.insert("q".into(), json!("rust"));
        let messages = vec![Message::Assistant {
            content: vec![
                AssistantContent::Thinking {
                    thinking: "Let me plan this...".into(),
                    signature: None,
                },
                AssistantContent::text("I'll search for that."),
                AssistantContent::CapabilityInvocation {
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
        assert_eq!(result[0].content, Some("I'll search for that.".into()));
        // Capability invocation preserved with object arguments
        let tc = result[0].capability_invocations.as_ref().unwrap();
        assert_eq!(tc[0].function.name, "search");
        assert_eq!(tc[0].function.arguments, json!({"q": "rust"}));
    }

    #[test]
    fn invocation_id_already_openai_format() {
        // IDs already in OpenAI format → no remapping needed, model_primitive_name still resolves
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "call_already_openai".into(),
                    name: "execute".into(),
                    arguments: serde_json::Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "call_already_openai".into(),
                content: CapabilityResultMessageContent::Text("done".into()),
                is_error: None,
            },
        ];
        let result = convert_messages(&messages, true);
        // ID passed through unchanged
        assert_eq!(
            result[0].capability_invocations.as_ref().unwrap()[0].id,
            "call_already_openai"
        );
        // model_primitive_name still resolved correctly
        assert_eq!(result[1].model_primitive_name, Some("execute".into()));
    }
}
