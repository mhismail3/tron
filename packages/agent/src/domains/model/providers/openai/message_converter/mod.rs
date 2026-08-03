//! # `OpenAI` Message Converter
//!
//! Converts between Tron message format and `OpenAI` Responses API format.
//! Handles tool invocation ID remapping for cross-provider DTO parity.
//!
//! Key behaviors:
//! - User messages → `input_text` / `input_image` content
//! - Assistant text → `output_text` content
//! - Tool invocations → `function_call` items with remapped IDs
//! - Tool results → byte-preserved `function_call_output` items
//! - Documents → placeholder text (`OpenAI` doesn't support documents directly)

use crate::domains::model::providers::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, ToolResultContent, UserContent};
use crate::shared::protocol::messages::{Message, ToolResultMessageContent, UserMessageContent};
use crate::shared::protocol::model_tools::ModelTool;

use super::types::{MessageContent, ResponsesInputItem, ResponsesToolEntry};

/// Convert Tron messages to Responses API input format.
///
/// Tool invocation IDs from other providers (e.g., Anthropic's `toolu_` prefix)
/// are remapped to `OpenAI`-compatible `call_` format for cross-provider support.
#[must_use]
pub fn convert_to_responses_input(messages: &[Message]) -> Vec<ResponsesInputItem> {
    let mut input = Vec::new();

    // Build tool invocation ID mapping for cross-provider switching
    let all_invocation_ids = collect_invocation_ids(messages);
    let id_refs: Vec<&str> = all_invocation_ids.iter().map(String::as_str).collect();
    let id_mapping = build_invocation_id_mapping(&id_refs, IdFormat::OpenAi);

    for msg in messages {
        match msg {
            Message::User { content, .. } => {
                convert_user_message(content, &mut input);
            }
            Message::Assistant { content, .. } => {
                convert_assistant_message(content, &id_mapping, &mut input);
            }
            Message::ToolResult {
                invocation_id,
                content,
                ..
            } => {
                convert_tool_result(invocation_id, content, &id_mapping, &mut input);
            }
        }
    }

    input
}

/// Convert Tron tools to Responses API tool entries.
///
/// The primitive branch always exports concrete function entries. Hosted
/// tool-search/deferred loading is intentionally ignored so provider requests
/// match the live direct kernel and worker surface.
#[must_use]
pub fn convert_tools_v2(tools: &[ModelTool]) -> Vec<ResponsesToolEntry> {
    tools
        .iter()
        .map(|t| {
            let schema = serde_json::to_value(&t.parameters).unwrap_or_default();
            let params = normalize_schema_for_openai(&schema);
            ResponsesToolEntry::Function {
                name: t.name.clone(),
                description: t.description.clone(),
                parameters: params,
            }
        })
        .collect()
}

/// Normalize a JSON schema for the `OpenAI` API.
///
/// `OpenAI` requires `"items"` on every `"type": "array"` schema.
/// This recursively walks the schema and adds `"items": {}` where missing.
pub fn normalize_schema_for_openai(schema: &serde_json::Value) -> serde_json::Value {
    match schema {
        serde_json::Value::Object(map) => {
            let mut patched = serde_json::Map::new();
            for (key, value) in map {
                let _ = patched.insert(key.clone(), normalize_schema_for_openai(value));
            }
            // If this object is an array type without `items`, add a permissive default.
            if patched.get("type").and_then(|v| v.as_str()) == Some("array")
                && !patched.contains_key("items")
            {
                let _ = patched.insert("items".into(), serde_json::json!({}));
            }
            serde_json::Value::Object(patched)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(normalize_schema_for_openai).collect())
        }
        other => other.clone(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Collect all tool invocation IDs from assistant messages.
fn collect_invocation_ids(messages: &[Message]) -> Vec<String> {
    let mut ids = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::ToolInvocation { id, .. } = block {
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
                    UserContent::Text { text } => MessageContent::InputText { text: text.clone() },
                    UserContent::Image { data, mime_type } => MessageContent::InputImage {
                        image_url: format!("data:{mime_type};base64,{data}"),
                        detail: Some("auto".into()),
                    },
                    UserContent::Document {
                        mime_type,
                        file_name,
                        extracted_text,
                        ..
                    } => {
                        let name = file_name.as_deref().unwrap_or("unnamed");
                        match extracted_text {
                            Some(text) => MessageContent::InputText {
                                text: format!("--- Document: {name} ---\n{text}"),
                            },
                            None => MessageContent::InputText {
                                text: format!("[Document: {name} ({mime_type}) \u{2014} content not available for this model]"),
                            },
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

    // Convert tool invocations to function_call items
    for block in content {
        if let AssistantContent::ToolInvocation {
            id,
            name,
            arguments,
            ..
        } = block
        {
            let remapped_id = remap_invocation_id(id, id_mapping).to_string();
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
    invocation_id: &str,
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

    let remapped_id = remap_invocation_id(invocation_id, id_mapping).to_string();
    input.push(ResponsesInputItem::FunctionCallOutput {
        call_id: remapped_id,
        output: output_text,
    });
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
#[allow(unused_results)]
mod tests;
