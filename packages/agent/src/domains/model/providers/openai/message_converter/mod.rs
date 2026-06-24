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
        Use ONLY this model-facing tool:\n\
        \n\
        {tool_list}\n\
        \n\
        ## Execute Operations\n\
        Each `execute` call performs one direct host operation. Set `operation` to exactly one of: \
        `observe`, `state_get`, `state_set`, `state_list`, `filesystem_read`, \
        `filesystem_list`, `filesystem_find`, `filesystem_glob`, \
        `filesystem_search_text`, `filesystem_diff`, `filesystem_write`, `filesystem_edit`, \
        `filesystem_apply_patch`, `git_status`, `git_diff`, `git_stage`, `git_unstage`, `git_commit`, `process_run`, `job_start`, `job_status`, `job_list`, \
        `job_log`, `job_cancel`, `trace_list`, `trace_get`, `log_recent`, `replay_manifest`, \
        `catalog_search`, `catalog_inspect`, `catalog_conformance`, `memory_status`, `memory_list`, or `memory_inspect`. \
        Do not send `target`, `contractId`, `functionId`, or `arguments`. \
        Catalog discovery operations inspect metadata/conformance only and never execute discovered \
        functions. Put operation fields at the top level of the execute payload. \
        Use `observe` to record reasoning-relevant facts, state operations for agent-owned memory, \
        filesystem package \
        operations for bounded read/list/find/glob/search/diff and preview-first write/edit/patch under \
        trusted roots, `git_status` and `git_diff` for read-only repository/worktree status and \
        bounded staged/unstaged diff evidence, `git_stage` and `git_unstage` for explicit relative-path Git index \
        mutations that require `expectedHead`, `reason`, and a stable `idempotencyKey`, `git_commit` for one already-staged index commit with `message`, `expectedHead`, `expectedIndexTree`, `reason`, and `idempotencyKey`, `process_run` for short bounded shell commands, job operations for durable \
        non-interactive command lifecycle/status/log/cancel, trace/log operations to inspect durable \
        execution records, `replay_manifest` to \
        export the current session's `tron.replay.v1` audit manifest, and catalog operations to inspect \
        available workers/functions/schemas/conformance evidence through the same execute primitive. \
        Mutating filesystem package operations require a stable `idempotencyKey`; include `reason`, use \
        preview mode before commit when possible, and provide `expectedHash` when committing changes to \
        an existing file. `job_start` and `job_cancel` require a stable `idempotencyKey`; other mutating \
        operations should include a short `reason`; repeated writes, Git index mutations, Git commits, or commands should include a stable \
        `idempotencyKey` when retry safety matters. Except for read-only `replay_manifest`, the engine records a trace \
        record for each execute operation with status, timing, provider/model context, authority metadata, \
        touched resources, hashes where available, errors, and implementation metadata.\n\
        \n\
        ## Important Rules\n\
        1. Use one operation per `execute` call\n\
        2. Inspect files before changing them unless the user explicitly provides full replacement content\n\
        3. Use relative paths under the current working directory\n\
        4. Prefer small, tested changes and record useful evidence through `observe` or trace inspection\n\
        5. When authority is unavailable, report the blocked state inside the current authority envelope\n\
        6. Be helpful, accurate, and efficient when working with code",
        tool_list = tool_descriptions.join("\n")
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
