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
        `observe`, `state_get`, `state_set`, `state_list`, `file_read`, `file_write`, `process_run`, \
        `trace_list`, or `trace_get`. Do not send `target`, `contractId`, `functionId`, `arguments`, \
        or catalog-search constraints. Put operation fields at the top level of the execute payload. \
        Use `observe` to record reasoning-relevant facts, state operations for agent-owned memory, \
        file operations for files under the current working directory, `process_run` for bounded shell \
        commands, and trace operations to inspect durable execution records. Mutating operations should \
        include a short `reason`; repeated writes or commands should include a stable `idempotencyKey` \
        when retry safety matters. The engine records a trace record for every execute operation with \
        status, timing, provider/model context, authority metadata, touched resources, hashes where \
        available, errors, and implementation metadata.\n\
        \n\
        ## Important Rules\n\
        1. Use one operation per `execute` call\n\
        2. Inspect files before changing them unless the user explicitly provides full replacement content\n\
        3. Use relative paths under the current working directory unless an absolute path is clearly required\n\
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
mod tests {
    use super::*;
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::messages::{
        CapabilityResultMessageContent, Message, UserMessageContent,
    };
    use crate::shared::protocol::model_capabilities::{CapabilityParameterSchema, ModelCapability};
    use serde_json::{Map, Value, json};

    fn make_tool(name: &str, desc: &str) -> ModelCapability {
        ModelCapability {
            name: name.into(),
            description: desc.into(),
            parameters: CapabilityParameterSchema {
                schema_type: "object".into(),
                properties: Some(Map::new()),
                required: Some(vec![]),
                description: None,
                extra: Map::new(),
            },
        }
    }

    fn make_tool_with_required(name: &str, desc: &str, required: Vec<&str>) -> ModelCapability {
        let mut props = Map::new();
        for r in &required {
            let mut prop = Map::new();
            prop.insert("type".into(), json!("string"));
            props.insert((*r).to_string(), Value::Object(prop));
        }
        ModelCapability {
            name: name.into(),
            description: desc.into(),
            parameters: CapabilityParameterSchema {
                schema_type: "object".into(),
                properties: Some(props),
                required: Some(required.into_iter().map(String::from).collect()),
                description: None,
                extra: Map::new(),
            },
        }
    }

    // ── convert_to_responses_input ──────────────────────────────────

    #[test]
    fn converts_string_user_messages() {
        let messages = vec![Message::user("Hello")];
        let result = convert_to_responses_input(&messages);

        assert_eq!(result.len(), 1);
        match &result[0] {
            ResponsesInputItem::Message { role, content, .. } => {
                assert_eq!(role, "user");
                assert_eq!(content.len(), 1);
                match &content[0] {
                    MessageContent::InputText { text } => assert_eq!(text, "Hello"),
                    _ => panic!("expected InputText"),
                }
            }
            _ => panic!("expected Message"),
        }
    }

    #[test]
    fn converts_user_text_content_blocks() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::text("Part 1"),
                UserContent::text("Part 2"),
            ]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            assert_eq!(content.len(), 2);
        } else {
            panic!("expected Message");
        }
    }

    #[test]
    fn converts_image_content() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::image(
                "base64data",
                "image/png",
            )]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            match &content[0] {
                MessageContent::InputImage { image_url, detail } => {
                    assert_eq!(image_url, "data:image/png;base64,base64data");
                    assert_eq!(detail.as_deref(), Some("auto"));
                }
                _ => panic!("expected InputImage"),
            }
        }
    }

    #[test]
    fn converts_document_to_placeholder() {
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::Document {
                data: "pdfdata".into(),
                mime_type: "application/pdf".into(),
                file_name: Some("doc.pdf".into()),
                extracted_text: None,
            }]),
            timestamp: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::Message { content, .. } = &result[0] {
            match &content[0] {
                MessageContent::InputText { text } => {
                    assert!(text.contains("doc.pdf"));
                    assert!(text.contains("content not available"));
                }
                _ => panic!("expected InputText"),
            }
        }
    }

    #[test]
    fn converts_assistant_text() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::text("Response")],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::Message { role, content, .. } = &result[0] {
            assert_eq!(role, "assistant");
            match &content[0] {
                MessageContent::OutputText { text } => assert_eq!(text, "Response"),
                _ => panic!("expected OutputText"),
            }
        }
    }

    #[test]
    fn converts_assistant_capability_invocations() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/test.txt"));
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_abc".into(),
                name: "read_file".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        assert!(func_call.is_some());
        if let ResponsesInputItem::FunctionCall {
            name, arguments, ..
        } = func_call.unwrap()
        {
            assert_eq!(name, "read_file");
            assert!(arguments.contains("path"));
        }
    }

    #[test]
    fn converts_capability_results() {
        let messages = vec![Message::CapabilityResult {
            invocation_id: "call_abc".into(),
            content: CapabilityResultMessageContent::Text("File contents here".into()),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        assert_eq!(result.len(), 1);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert_eq!(output, "File contents here");
        } else {
            panic!("expected FunctionCallOutput");
        }
    }

    #[test]
    fn converts_capability_result_content_blocks() {
        let messages = vec![Message::CapabilityResult {
            invocation_id: "call_abc".into(),
            content: CapabilityResultMessageContent::Blocks(vec![
                CapabilityResultContent::text("Line 1"),
                CapabilityResultContent::text("Line 2"),
            ]),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert_eq!(output, "Line 1\nLine 2");
        }
    }

    #[test]
    fn truncates_long_capability_results() {
        let long_output = "x".repeat(20000);
        let messages = vec![Message::CapabilityResult {
            invocation_id: "call_abc".into(),
            content: CapabilityResultMessageContent::Text(long_output),
            is_error: None,
        }];

        let result = convert_to_responses_input(&messages);
        if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
            assert!(output.len() <= TOOL_RESULT_MAX_LENGTH + 20);
            assert!(output.contains("[truncated]"));
        }
    }

    #[test]
    fn handles_empty_capability_invocation_arguments() {
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_1".into(),
                name: "get_status".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];

        let result = convert_to_responses_input(&messages);
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        if let Some(ResponsesInputItem::FunctionCall { arguments, .. }) = func_call {
            assert_eq!(arguments, "{}");
        }
    }

    #[test]
    fn remaps_anthropic_invocation_ids() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/test"));
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "toolu_01abc".into(),
                    name: "read_file".into(),
                    arguments: args,
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "toolu_01abc".into(),
                content: CapabilityResultMessageContent::Text("result".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        // Both the function_call and function_call_output should use remapped IDs
        let func_call = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }));
        let func_output = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCallOutput { .. }));

        if let Some(ResponsesInputItem::FunctionCall { call_id, .. }) = func_call {
            assert!(
                call_id.starts_with("call_"),
                "expected call_ prefix, got: {call_id}"
            );
        }
        if let Some(ResponsesInputItem::FunctionCallOutput { call_id, .. }) = func_output {
            assert!(
                call_id.starts_with("call_"),
                "expected call_ prefix, got: {call_id}"
            );
        }
    }

    #[test]
    fn preserves_openai_invocation_ids() {
        let messages = vec![
            Message::Assistant {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: "call_existing".into(),
                    name: "execute".into(),
                    arguments: Map::new(),
                    thought_signature: None,
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "call_existing".into(),
                content: CapabilityResultMessageContent::Text("ok".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        if let Some(ResponsesInputItem::FunctionCall { call_id, .. }) = result
            .iter()
            .find(|item| matches!(item, ResponsesInputItem::FunctionCall { .. }))
        {
            assert_eq!(call_id, "call_existing");
        }
    }

    #[test]
    fn handles_mixed_conversation() {
        let mut args = Map::new();
        args.insert("path".into(), json!("/f.txt"));
        let messages = vec![
            Message::user("Read file"),
            Message::Assistant {
                content: vec![
                    AssistantContent::text("Reading..."),
                    AssistantContent::CapabilityInvocation {
                        id: "call_1".into(),
                        name: "inspect".into(),
                        arguments: args,
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::CapabilityResult {
                invocation_id: "call_1".into(),
                content: CapabilityResultMessageContent::Text("file data".into()),
                is_error: None,
            },
        ];

        let result = convert_to_responses_input(&messages);
        // user message + assistant text + function_call + function_call_output
        assert_eq!(result.len(), 4);
    }

    #[test]
    fn empty_messages_returns_empty() {
        let result = convert_to_responses_input(&[]);
        assert!(result.is_empty());
    }

    // ── convert_tools_v2 ────────────────────────────────────────────

    #[test]
    fn convert_tools_v2_exports_function_entries() {
        use crate::domains::model::providers::openai::types::ResponsesToolEntry;
        let capabilities = vec![
            make_tool("execute", "Run commands"),
            make_tool("inspect", "Read file"),
        ];
        let result = convert_tools_v2(&capabilities);

        assert_eq!(result.len(), 2);
        for entry in &result {
            match entry {
                ResponsesToolEntry::Function { .. } => {}
            }
        }
    }

    #[test]
    fn convert_tools_v2_exports_single_execute_function_for_primitive_branch() {
        use crate::domains::model::providers::openai::types::ResponsesToolEntry;
        let capabilities = vec![make_tool("execute", "Run primitive host operations")];
        let result = convert_tools_v2(&capabilities);

        assert_eq!(result.len(), 1);
        match &result[0] {
            ResponsesToolEntry::Function { name, .. } => {
                assert_eq!(name, "execute");
            }
        }
    }

    #[test]
    fn convert_tools_v2_json_shape() {
        let capabilities = vec![make_tool("execute", "Run commands")];
        let result = convert_tools_v2(&capabilities);
        let json = serde_json::to_value(&result).unwrap();
        let arr = json.as_array().unwrap();

        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["type"], "function");
        assert_eq!(arr[0]["name"], "execute");
    }

    #[test]
    fn convert_tools_v2_empty_tools() {
        let result = convert_tools_v2(&[]);
        assert!(result.is_empty());
    }

    // ── generate_capability_instruction_text ──────────────────────────────

    #[test]
    fn clarification_includes_model_primitive_names() {
        let capabilities = vec![make_tool_with_required(
            "execute",
            "Execute inspected capabilities",
            vec!["mode"],
        )];
        let result = generate_capability_instruction_text(&capabilities);

        assert!(result.contains("execute"));
        assert!(result.contains("Execute inspected capabilities"));
        assert!(result.contains("required params: mode"));
    }

    #[test]
    fn clarification_includes_tron_identity() {
        let result = generate_capability_instruction_text(&[]);
        assert!(result.contains("TRON"));
        assert!(result.contains("AI coding assistant"));
    }

    #[test]
    fn clarification_includes_capability_execution_guidance() {
        let result = generate_capability_instruction_text(&[]);
        assert!(result.contains("Execute Operations"));
        assert!(result.contains("state_get"));
        assert!(result.contains("file_write"));
        assert!(result.contains("process_run"));
        assert!(result.contains("trace_list"));
        assert!(result.contains("Do not send `target`"));
        assert!(result.contains("Put operation fields at the top level"));
        assert!(result.contains("The engine records a trace record"));
        assert!(result.contains("When authority is unavailable"));
    }

    #[test]
    fn clarification_forbids_probe_calls_when_user_supplies_exact_payload() {
        let result = generate_capability_instruction_text(&[]);

        assert!(result.contains("Use ONLY this model-facing tool"));
        assert!(result.contains("Each `execute` call performs one direct host operation"));
        assert!(result.contains("Do not send `target`, `contractId`, `functionId`, `arguments`"));
        assert!(result.contains("Put operation fields at the top level"));
        assert!(result.contains("Use one operation per `execute` call"));
        assert!(result.contains("When authority is unavailable"));
    }

    // ── normalize_schema_for_openai ──────────────────────────────────

    #[test]
    fn normalize_adds_items_to_bare_array() {
        let schema = json!({"type": "array", "description": "tags"});
        let result = normalize_schema_for_openai(&schema);
        assert_eq!(result["items"], json!({}));
        assert_eq!(result["description"], "tags");
    }

    #[test]
    fn normalize_preserves_existing_items() {
        let schema = json!({"type": "array", "items": {"type": "string"}});
        let result = normalize_schema_for_openai(&schema);
        assert_eq!(result["items"], json!({"type": "string"}));
    }

    #[test]
    fn normalize_recurses_into_properties() {
        let schema = json!({
            "type": "object",
            "properties": {
                "tags": {"type": "array", "description": "list of tags"},
                "name": {"type": "string"}
            }
        });
        let result = normalize_schema_for_openai(&schema);
        assert_eq!(result["properties"]["tags"]["items"], json!({}));
        assert_eq!(result["properties"]["name"]["type"], "string");
    }

    #[test]
    fn normalize_leaves_non_array_types_unchanged() {
        let schema = json!({"type": "object", "properties": {"x": {"type": "number"}}});
        let result = normalize_schema_for_openai(&schema);
        assert_eq!(result, schema);
    }
}
