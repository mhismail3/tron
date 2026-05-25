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
use crate::shared::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::messages::{CapabilityResultMessageContent, Message, UserMessageContent};
use crate::shared::model_capabilities::ModelCapability;

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
/// When `enable_tool_search` is `true`, marks all functions with `defer_loading: true`
/// and appends a `ToolSearch` sentinel. This enables the model to dynamically discover
/// which capabilities to use, reducing prompt tokens for large tool sets.
///
/// When `false`, produces standard function entries with no `defer_loading` field.
#[must_use]
pub fn convert_tools_v2(
    capabilities: &[ModelCapability],
    enable_tool_search: bool,
) -> Vec<ResponsesToolEntry> {
    let mut entries: Vec<ResponsesToolEntry> = capabilities
        .iter()
        .map(|t| {
            let schema = serde_json::to_value(&t.parameters).unwrap_or_default();
            let params = normalize_schema_for_openai(&schema);
            ResponsesToolEntry::Function {
                name: t.name.clone(),
                description: t.description.clone(),
                parameters: params,
                defer_loading: if enable_tool_search { Some(true) } else { None },
            }
        })
        .collect();

    if enable_tool_search {
        entries.push(ResponsesToolEntry::ToolSearch {});
    }

    entries
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

/// Generate a tool clarification message for the first turn.
///
/// Since `OpenAI` Codex has its own built-in system instructions that reference
/// capabilities we don't use (shell, `apply_patch`, etc.), we prepend this message to
/// clarify the actual available capabilities.
#[must_use]
pub fn generate_capability_clarification_message(
    capabilities: &[ModelCapability],
    working_directory: Option<&str>,
) -> String {
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

    let cwd_line = working_directory
        .map(|d| format!("\nCurrent working directory: {d}"))
        .unwrap_or_default();

    format!(
        "[TRON CONTEXT]\n\
        You are Tron, an AI coding assistant that acts through Tron's live capability system.\n\
        {cwd_line}\n\
        \n\
        ## Available Capabilities\n\
        The capabilities mentioned in the system instructions (shell, apply_patch, etc.) are NOT available. \
        Use ONLY these tools:\n\
        \n\
        {tool_list}\n\
        \n\
        ## Capability Execution\n\
        Use `execute` for every capability task. It is intent-first: if you do not already know the \
        exact capability, call `execute` with intent only (and optional constraints). Do not invent a \
        target for discovery, matching, or shape tests. Use `target` only when the user supplied an \
        exact id, a prior `execute` result selected it, or a primed recipe makes it unambiguous. Put \
        only target capability arguments inside `arguments`; wrapper fields such as `target`, \
        `idempotencyKey`, `reason`, and `constraints` stay top-level. The engine resolves, prepares, \
        checks freshness, requests approval when needed, runs, and observes.\n\
        Common contracts include filesystem capabilities for file operations, `process::run` for \
        command execution, and web capabilities for network retrieval when they are visible to the session.\n\
        If the user gives an exact contract id and arguments, call that exact target once; do not run \
        warm-up, probe, date, status, or example commands first.\n\
        \n\
        ## Important Rules\n\
        1. If the target or required fields are uncertain, call `execute` with a clear intent first; do not guess a target or fabricate arguments\n\
        2. You MUST provide ALL known required target parameters when invoking a selected capability - never call with empty arguments after a target is selected\n\
        3. Never execute sample/example capability payloads as exploratory calls; examples are templates only\n\
        4. When `execute` returns `needs_input`, retry only the same selected target with the missing required parameters, not an unrelated probe\n\
        5. For file paths, provide the complete path (e.g., \"src/index.ts\" or \"/absolute/path/file.txt\")\n\
        6. Confidently interpret and explain results from capability invocations - you have full context of what was returned\n\
        7. Be helpful, accurate, and efficient when working with code\n\
        8. Inspect/read existing files through capabilities before changing them\n\
        9. Make targeted, minimal edits rather than rewriting entire files",
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
    use crate::shared::content::AssistantContent;
    use crate::shared::messages::{CapabilityResultMessageContent, Message, UserMessageContent};
    use crate::shared::model_capabilities::{CapabilityParameterSchema, ModelCapability};
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
    fn convert_tools_v2_without_tool_search() {
        use crate::domains::model::providers::openai::types::ResponsesToolEntry;
        let capabilities = vec![
            make_tool("execute", "Run commands"),
            make_tool("inspect", "Read file"),
        ];
        let result = convert_tools_v2(&capabilities, false);

        assert_eq!(result.len(), 2);
        for entry in &result {
            match entry {
                ResponsesToolEntry::Function { defer_loading, .. } => {
                    assert!(defer_loading.is_none());
                }
                _ => panic!("expected Function entry"),
            }
        }
    }

    #[test]
    fn convert_tools_v2_with_tool_search() {
        use crate::domains::model::providers::openai::types::ResponsesToolEntry;
        let capabilities = vec![
            make_tool("execute", "Run commands"),
            make_tool("inspect", "Read file"),
        ];
        let result = convert_tools_v2(&capabilities, true);

        // 2 functions + 1 tool_search sentinel
        assert_eq!(result.len(), 3);

        // All functions should have defer_loading: true
        for entry in &result[..2] {
            match entry {
                ResponsesToolEntry::Function { defer_loading, .. } => {
                    assert_eq!(*defer_loading, Some(true));
                }
                _ => panic!("expected Function entry"),
            }
        }

        // Last entry should be ToolSearch
        assert!(matches!(&result[2], ResponsesToolEntry::ToolSearch {}));
    }

    #[test]
    fn convert_tools_v2_tool_search_json_shape() {
        let capabilities = vec![make_tool("execute", "Run commands")];
        let result = convert_tools_v2(&capabilities, true);
        let json = serde_json::to_value(&result).unwrap();
        let arr = json.as_array().unwrap();

        // Function with defer_loading
        assert_eq!(arr[0]["type"], "function");
        assert_eq!(arr[0]["defer_loading"], true);
        assert_eq!(arr[0]["name"], "execute");

        // ModelCapability search sentinel
        assert_eq!(arr[1]["type"], "tool_search");
    }

    #[test]
    fn convert_tools_v2_empty_tools_with_search() {
        use crate::domains::model::providers::openai::types::ResponsesToolEntry;
        let result = convert_tools_v2(&[], true);
        assert_eq!(result.len(), 1);
        assert!(matches!(&result[0], ResponsesToolEntry::ToolSearch {}));
    }

    // ── generate_capability_clarification_message ─────────────────────────

    #[test]
    fn clarification_includes_model_primitive_names() {
        let capabilities = vec![make_tool_with_required(
            "execute",
            "Execute inspected capabilities",
            vec!["mode"],
        )];
        let result = generate_capability_clarification_message(&capabilities, None);

        assert!(result.contains("execute"));
        assert!(result.contains("Execute inspected capabilities"));
        assert!(result.contains("required params: mode"));
    }

    #[test]
    fn clarification_includes_working_directory() {
        let capabilities = vec![];
        let result =
            generate_capability_clarification_message(&capabilities, Some("/home/user/project"));
        assert!(result.contains("/home/user/project"));
    }

    #[test]
    fn clarification_includes_tron_identity() {
        let result = generate_capability_clarification_message(&[], None);
        assert!(result.contains("TRON"));
        assert!(result.contains("AI coding assistant"));
    }

    #[test]
    fn clarification_includes_capability_execution_guidance() {
        let result = generate_capability_clarification_message(&[], None);
        assert!(result.contains("Capability Execution"));
        assert!(result.contains("process::run"));
        assert!(result.contains("Use `execute` for every capability task"));
        assert!(result.contains("It is intent-first"));
        assert!(result.contains("Do not invent a"));
        assert!(result.contains("target for discovery"));
        assert!(result.contains("only target capability arguments inside `arguments`"));
        assert!(result.contains("The engine resolves, prepares"));
    }

    #[test]
    fn clarification_forbids_probe_calls_when_user_supplies_exact_payload() {
        let result = generate_capability_clarification_message(&[], None);

        assert!(result.contains("exact contract id and arguments"));
        assert!(result.contains("call that exact target once"));
        assert!(
            result.contains("do not run warm-up, probe, date, status, or example commands first")
        );
        assert!(result.contains("examples are templates only"));
        assert!(result.contains("When `execute` returns `needs_input`"));
        assert!(result.contains("retry only the same selected target"));
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
