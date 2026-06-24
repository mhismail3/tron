//! Message format conversion: Tron messages → Ollama native `/api/chat` format.
//!
//! Ollama's native API is similar to OpenAI chat completions but differs in two
//! key ways for tool calling:
//!
//! - **Tool call arguments** are JSON objects, not JSON-encoded strings.
//! - **Tool result messages** use `tool_name` (function name) instead of `invocation_id`.
//!
//! This module converts Tron's internal message types to the native wire format.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domains::model::providers::id_remapping::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};
use crate::shared::protocol::model_capabilities::ModelCapability;

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
    /// Tool calls made by the assistant.
    #[serde(rename = "tool_calls", skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ChatCapabilityInvocationDraft>>,
    /// Tool name (for tool result messages).
    ///
    /// Ollama's native `/api/chat` uses `tool_name` (the function name) to match
    /// results to calls, not `invocation_id` like OpenAI's API.
    #[serde(rename = "tool_name", skip_serializing_if = "Option::is_none")]
    pub tool_name: Option<String>,
}

/// A tool call in Ollama's native format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChatCapabilityInvocationDraft {
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

/// Build a tool call ID mapping for all messages (Anthropic → OpenAI format).
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
            tool_calls: None,
            tool_name: None,
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
                tool_calls: None,
                tool_name: None,
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
    let mut tool_calls = Vec::new();

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
                tool_calls.push(ChatCapabilityInvocationDraft {
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
        images: None,
        tool_calls: tool_calls_opt,
        tool_name: None,
    })
}

/// Convert a tool result to chat format.
///
/// Ollama's native `/api/chat` matches tool results to calls via `tool_name`
/// (the function name), not `invocation_id` like OpenAI's API.
fn convert_capability_result(
    tool_name: &str,
    content: &CapabilityResultMessageContent,
) -> ChatMessage {
    let text = match content {
        CapabilityResultMessageContent::Text(t) => t.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => {
            use crate::shared::protocol::content::CapabilityResultContent;
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
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                let tool_name = tool_name_mapping
                    .get(invocation_id.as_str())
                    .cloned()
                    .unwrap_or_else(|| "unknown".to_string());
                result.push(convert_capability_result(&tool_name, content));
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
mod tests;
