//! # Message Converter
//!
//! Converts core [`Context`] messages into Anthropic Messages API format.
//! Handles:
//! - User/assistant/internal capability-result message conversion
//! - Thinking block signature handling (only include with signature)
//! - Capability invocation ID remapping for cross-provider DTO parity
//! - System prompt construction with cache breakpoints (all auth types)
//! - ModelCapability definitions with cache control

use std::collections::HashMap;

use crate::domains::model::providers::{
    IdFormat, build_invocation_id_mapping, compose_context_parts_grouped, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Context, Message, UserMessageContent,
};
use serde_json::{Value, json};

use super::types::{AnthropicMessageParam, AnthropicTool, CacheControl, SystemPromptBlock};

// ─────────────────────────────────────────────────────────────────────────────
// Message conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a [`Context`] into Anthropic Messages API parameters.
///
/// Returns `(system, messages, capabilities)` where:
/// - `system` is the system prompt as an array of blocks with cache breakpoints
/// - `messages` is the list of Anthropic message params
/// - `tools` is the optional tool list
///
/// `prefix` is an optional system prompt prefix block (e.g. OAuth identification).
/// Caching is always applied regardless of auth type.
pub fn convert_context(
    context: &Context,
    prefix: Option<&str>,
) -> (
    Option<Value>,
    Vec<AnthropicMessageParam>,
    Option<Vec<AnthropicTool>>,
) {
    // Build capability invocation ID mapping for cross-provider DTO parity.
    let id_mapping = build_id_mapping(&context.messages);

    // Convert messages
    let messages = convert_messages_impl(&context.messages, &id_mapping);

    // Convert tools
    let capabilities = context.capabilities.as_ref().map(|t| convert_tools(t));

    // Build system prompt
    let system = build_system_prompt(context, prefix);

    (system, messages, capabilities)
}

/// Build capability invocation ID mapping from messages for cross-provider DTO parity.
fn build_id_mapping(messages: &[Message]) -> HashMap<String, String> {
    let mut all_capability_invocations = Vec::new();
    for msg in messages {
        if let Message::Assistant { content, .. } = msg {
            for c in content {
                if let AssistantContent::CapabilityInvocation { id, .. } = c {
                    all_capability_invocations.push(id.as_str());
                }
            }
        }
    }
    build_invocation_id_mapping(&all_capability_invocations, IdFormat::Anthropic)
}

/// Convert conversation messages to Anthropic format.
///
/// Builds capability invocation ID remapping internally, converting OpenAI-format
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
            Message::CapabilityResult {
                invocation_id,
                content,
                is_error,
            } => {
                result.push(convert_capability_result(
                    invocation_id,
                    content,
                    *is_error,
                    id_mapping,
                ));
            }
        }
    }

    let merged = merge_consecutive_roles(result);
    dedup_tool_blocks(merged)
}

/// Merge consecutive messages with the same role into a single message.
///
/// The Anthropic API requires alternating user/assistant roles. Multiple
/// consecutive `ToolResult` messages (each converted to `role: "user"`) would
/// violate this. This function merges their content blocks into a single message.
fn merge_consecutive_roles(messages: Vec<AnthropicMessageParam>) -> Vec<AnthropicMessageParam> {
    let mut merged: Vec<AnthropicMessageParam> = Vec::with_capacity(messages.len());
    for msg in messages {
        if let Some(prev) = merged.last_mut()
            && prev.role == msg.role
        {
            prev.content.extend(msg.content);
            continue;
        }
        merged.push(msg);
    }
    merged
}

/// Deduplicate tool blocks within messages.
///
/// Normalizes duplicate tool blocks before sending the provider request:
/// - In assistant messages: duplicate `tool_use` blocks with same `id` → keep last
/// - In user messages: duplicate `tool_result` blocks with same `tool_use_id` → keep last
fn dedup_tool_blocks(messages: Vec<AnthropicMessageParam>) -> Vec<AnthropicMessageParam> {
    messages
        .into_iter()
        .map(|mut msg| {
            let key = if msg.role == "assistant" {
                "id"
            } else {
                "tool_use_id"
            };
            let block_type = if msg.role == "assistant" {
                "tool_use"
            } else {
                "tool_result"
            };

            // Track seen IDs — keep last occurrence by reversing, dedup, then reverse back
            let mut seen = std::collections::HashSet::new();
            let mut deduped: Vec<Value> = msg
                .content
                .into_iter()
                .rev()
                .filter(|block| {
                    if block.get("type").and_then(|t| t.as_str()) == Some(block_type)
                        && let Some(id) = block.get(key).and_then(|v| v.as_str())
                    {
                        return seen.insert(id.to_owned());
                    }
                    true // non-tool blocks always kept
                })
                .collect();
            deduped.reverse();
            msg.content = deduped;
            msg
        })
        .collect()
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
        UserContent::Document {
            data,
            mime_type,
            file_name,
            extracted_text,
        } => {
            // Anthropic document blocks only accept application/pdf.
            // For text-based files, inline the extracted text instead.
            if mime_type == "application/pdf" {
                json!({
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": mime_type,
                        "data": data,
                    }
                })
            } else if let Some(text) = extracted_text {
                let name = file_name.as_deref().unwrap_or("unnamed");
                json!({"type": "text", "text": format!("--- Document: {name} ---\n{text}")})
            } else {
                let name = file_name.as_deref().unwrap_or("unnamed");
                json!({"type": "text", "text": format!("[Document: {name} ({mime_type})]")})
            }
        }
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
        AssistantContent::CapabilityInvocation {
            id,
            name,
            arguments,
            ..
        } => {
            let remapped_id = remap_invocation_id(id, id_mapping);
            Some(json!({
                "type": "tool_use",
                "id": remapped_id,
                "name": name,
                "input": arguments,
            }))
        }
    }
}

/// Convert a capability result message to Anthropic format.
fn convert_capability_result(
    invocation_id: &str,
    content: &CapabilityResultMessageContent,
    is_error: Option<bool>,
    id_mapping: &HashMap<String, String>,
) -> AnthropicMessageParam {
    let remapped_id = remap_invocation_id(invocation_id, id_mapping);

    let result_content = match content {
        CapabilityResultMessageContent::Text(text) => vec![json!({"type": "text", "text": text})],
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .map(convert_capability_result_content)
            .collect(),
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

/// Convert a capability result content block to Anthropic JSON.
fn convert_capability_result_content(content: &CapabilityResultContent) -> Value {
    match content {
        CapabilityResultContent::Text { text } => json!({"type": "text", "text": text}),
        CapabilityResultContent::Image { data, mime_type } => json!({
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

/// Build the system prompt for use by the provider.
///
/// This is the public entry point for `provider.rs` to call.
pub fn build_system_prompt_for_provider(context: &Context, prefix: Option<&str>) -> Option<Value> {
    build_system_prompt(context, prefix)
}

/// Build the system prompt value with cache breakpoints.
///
/// Returns an array of [`SystemPromptBlock`]s with cache breakpoints for all auth types.
/// When `prefix` is `Some`, it is prepended as the first block (e.g. OAuth identification).
/// When `prefix` is `None` and there is no content, returns `None`.
///
/// Cache breakpoints:
/// - Breakpoint 2: Last stable instruction block -> 1h TTL
/// - Breakpoint 3: Last volatile state block -> 5m TTL (default)
fn build_system_prompt(context: &Context, prefix: Option<&str>) -> Option<Value> {
    let grouped = compose_context_parts_grouped(context);

    let mut blocks: Vec<SystemPromptBlock> = Vec::new();

    // Optional prefix (first block)
    let prefix_offset = if let Some(pfx) = prefix {
        blocks.push(SystemPromptBlock::text(pfx));
        1
    } else {
        0
    };

    // Stable instruction parts: cache at 1h.
    for part in &grouped.stable {
        blocks.push(SystemPromptBlock::text(part));
    }

    // Volatile state parts: cache at 5m.
    for part in &grouped.volatile {
        blocks.push(SystemPromptBlock::text(part));
    }

    if blocks.is_empty() {
        return None;
    }

    // Only prefix, no content
    if blocks.len() == prefix_offset && prefix.is_some() {
        blocks[0].cache_control = Some(CacheControl {
            cache_type: "ephemeral".into(),
            ttl: None,
        });
    } else if !grouped.volatile.is_empty() {
        // Has volatile content — 1h on last stable, 5m on last volatile
        let last_stable_idx = prefix_offset + grouped.stable.len();
        if last_stable_idx > prefix_offset && last_stable_idx <= blocks.len() {
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

    Some(serde_json::to_value(&blocks).expect("SystemPromptBlock serialization"))
}

// ─────────────────────────────────────────────────────────────────────────────
// ModelCapability conversion
// ─────────────────────────────────────────────────────────────────────────────

/// Convert context capabilities to Anthropic format with cache control.
///
/// The last tool always gets a 1h cache control breakpoint (Breakpoint 1).
fn convert_tools(
    capabilities: &[crate::shared::protocol::model_capabilities::ModelCapability],
) -> Vec<AnthropicTool> {
    let mut result: Vec<AnthropicTool> = capabilities
        .iter()
        .map(|t| AnthropicTool {
            name: t.name.clone(),
            description: t.description.clone(),
            input_schema: serde_json::to_value(&t.parameters).unwrap_or_default(),
            cache_control: None,
        })
        .collect();

    // Breakpoint 1: Last tool gets 1h cache
    if let Some(last) = result.last_mut() {
        last.cache_control = Some(CacheControl {
            cache_type: "ephemeral".into(),
            ttl: Some("1h".into()),
        });
    }

    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "message_converter/tests.rs"]
mod tests;
