//! # `OpenAI` Message Converter
//!
//! Converts between Tron message format and `OpenAI` Responses API format.
//! Handles capability invocation ID remapping for cross-provider DTO parity.
//!
//! Key behaviors:
//! - User messages → `input_text` / `input_image` content
//! - Assistant text → `output_text` content
//! - Capability invocations → `function_call` items with remapped IDs
//! - Capability results → `function_call_output` items (truncated at 16k)
//! - Documents → placeholder text (`OpenAI` doesn't support documents directly)

use crate::domains::capability::operation_list_text;
use crate::domains::model::providers::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Message, UserMessageContent,
};
use crate::shared::protocol::model_capabilities::ModelCapability;

use super::types::{
    MessageContent, ResponsesInputItem, ResponsesToolEntry, TOOL_RESULT_MAX_LENGTH,
};

/// Convert Tron messages to Responses API input format.
///
/// Capability invocation IDs from other providers (e.g., Anthropic's `toolu_` prefix)
/// are remapped to `OpenAI`-compatible `call_` format for cross-provider support.
#[must_use]
pub fn convert_to_responses_input(messages: &[Message]) -> Vec<ResponsesInputItem> {
    let mut input = Vec::new();

    // Build capability invocation ID mapping for cross-provider switching
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
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                convert_capability_result(invocation_id, content, &id_mapping, &mut input);
            }
        }
    }

    input
}

/// Convert Tron capabilities to Responses API tool entries.
///
/// The primitive branch always exports concrete function entries. Hosted
/// tool-search/deferred loading is intentionally ignored so provider requests
/// match the single checked-in `execute` surface.
#[must_use]
pub fn convert_tools_v2(capabilities: &[ModelCapability]) -> Vec<ResponsesToolEntry> {
    capabilities
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

/// Generate provider instruction text for the single `execute` primitive.
///
/// Since `OpenAI` Codex has its own built-in system instructions that reference
/// capabilities we don't use (shell, `apply_patch`, etc.), this text clarifies
/// the actual available capability surface in the request instructions.
#[must_use]
pub fn generate_capability_instruction_text(capabilities: &[ModelCapability]) -> String {
    let tool_descriptions: Vec<String> = capabilities
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
            format!(
                "- **{}**: {} (required params: {required})",
                t.name, t.description
            )
        })
        .collect();

    format!(
        "[TRON CONTEXT]\n\
        You are Tron, an AI coding assistant running in Tron's primitive loop.\n\
        \n\
        ## Available Primitive\n\
        Use only `capability::execute` (the model-facing `execute` tool):\n\
        \n\
        {tool_list}\n\
        \n\
        ## Schema-Led Execution\n\
        Canonical operation index (generated from engine contracts; discovery only): {operation_list}.\n\
        1. Use one operation per call and put its fields at the top level. Do not invoke from the \
        index alone.\n\
        2. Never guess operation names. Run `catalog_search`, then `catalog_inspect` with \
        `kind: \"function\"` and the exact `id: \"execute::<operation>\"` before invoking the selected operation.\n\
        3. The canonical inspect schema owns the exact required fields, effect, risk, preflight, \
        and output contract. Every non-read-only schema structurally requires a stable, \
        caller-supplied `idempotencyKey`.\n\
        4. Use exact refs and selectors returned by catalog and operation outputs; do not infer \
        aliases, wildcard selectors, or resource identifiers.\n\
        5. Normal task invocation must not enter a capability replacement workflow unless the user \
        explicitly requests replacement.\n\
        6. If a call is invalid or unsupported, recover by catalog inspection: run `catalog_search`, \
        inspect the exact `execute::<operation>` contract, and do not retry guessed variants.\n\
        7. Provider-safe outputs are the model-first evidence path. Continue and answer from those \
        projections instead of bypassing them for raw internal state.",
        tool_list = tool_descriptions.join("\n"),
        operation_list = operation_list_text(),
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Collect all capability invocation IDs from assistant messages.
fn collect_invocation_ids(messages: &[Message]) -> Vec<String> {
    let mut ids = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for block in content {
                if let AssistantContent::CapabilityInvocation { id, .. } = block {
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

    // Convert capability invocations to function_call items
    for block in content {
        if let AssistantContent::CapabilityInvocation {
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

/// Convert a capability result to a Responses API `function_call_output` item.
fn convert_capability_result(
    invocation_id: &str,
    content: &CapabilityResultMessageContent,
    id_mapping: &std::collections::HashMap<String, String>,
    input: &mut Vec<ResponsesInputItem>,
) {
    let output_text = match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| {
                if let CapabilityResultContent::Text { text } = block {
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

    let remapped_id = remap_invocation_id(invocation_id, id_mapping).to_string();
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
mod tests;
