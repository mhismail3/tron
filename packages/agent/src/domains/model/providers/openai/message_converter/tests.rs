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
        content: UserMessageContent::Blocks(vec![UserContent::image("base64data", "image/png")]),
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
    assert!(result.contains("filesystem_read"));
    assert!(result.contains("filesystem_write"));
    assert!(result.contains("git_status"));
    assert!(result.contains("git_diff"));
    assert!(result.contains("git_stage"));
    assert!(result.contains("git_unstage"));
    assert!(result.contains("git_commit"));
    assert!(result.contains("expectedHead"));
    assert!(result.contains("expectedIndexTree"));
    assert!(!result.contains("git_push"));
    assert!(!result.contains("git_reset"));
    assert!(!result.contains("file_read"));
    assert!(!result.contains("file_write"));
    assert!(result.contains("process_run"));
    assert!(result.contains("trace_list"));
    assert!(result.contains("replay_manifest"));
    assert!(result.contains("Do not send `target`"));
    assert!(result.contains("Put operation fields at the top level"));
    assert!(result.contains("Except for read-only `replay_manifest`"));
    assert!(result.contains("When authority is unavailable"));
}

#[test]
fn clarification_forbids_probe_calls_when_user_supplies_exact_payload() {
    let result = generate_capability_instruction_text(&[]);

    assert!(result.contains("Use ONLY this model-facing tool"));
    assert!(result.contains("Each `execute` call performs one direct host operation"));
    assert!(result.contains("catalog_search"));
    assert!(result.contains("catalog_inspect"));
    assert!(result.contains("catalog_conformance"));
    assert!(result.contains("Do not send `target`, `contractId`, `functionId`, or `arguments`"));
    assert!(result.contains("Catalog discovery operations inspect metadata/conformance only"));
    assert!(result.contains("Put operation fields at the top level"));
    assert!(result.contains("Use one operation per `execute` call"));
    assert!(result.contains("Use relative paths under the current working directory"));
    assert!(!result.contains("absolute path is clearly required"));
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
