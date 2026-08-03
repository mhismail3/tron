use super::*;
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::messages::{Message, ToolResultMessageContent, UserMessageContent};
use crate::shared::protocol::model_tools::{ModelTool, ToolParameterSchema};
use serde_json::{Map, json};

fn make_tool(name: &str, desc: &str) -> ModelTool {
    ModelTool {
        name: name.into(),
        description: desc.into(),
        parameters: ToolParameterSchema {
            schema_type: "object".into(),
            properties: Some(Map::new()),
            required: Some(vec![]),
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
fn converts_assistant_tool_invocations() {
    let mut args = Map::new();
    args.insert("path".into(), json!("/test.txt"));
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::ToolInvocation {
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
fn converts_tool_results() {
    let messages = vec![Message::ToolResult {
        invocation_id: "call_abc".into(),
        content: ToolResultMessageContent::Text("File contents here".into()),
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
fn converts_tool_result_content_blocks() {
    let messages = vec![Message::ToolResult {
        invocation_id: "call_abc".into(),
        content: ToolResultMessageContent::Blocks(vec![
            ToolResultContent::text("Line 1"),
            ToolResultContent::text("Line 2"),
        ]),
        is_error: None,
    }];

    let result = convert_to_responses_input(&messages);
    if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
        assert_eq!(output, "Line 1\nLine 2");
    }
}

#[test]
fn preserves_tool_result_bytes_exactly() {
    let output_envelope = format!(
        "{{\"summary\":\"{}\",\"kind\":\"test\"}}",
        "safe-évidence-".repeat(1_400)
    );
    let messages = vec![Message::ToolResult {
        invocation_id: "call_abc".into(),
        content: ToolResultMessageContent::Text(output_envelope.clone()),
        is_error: None,
    }];

    let result = convert_to_responses_input(&messages);
    if let ResponsesInputItem::FunctionCallOutput { output, .. } = &result[0] {
        assert_eq!(output.as_bytes(), output_envelope.as_bytes());
    }
}

#[test]
fn handles_empty_tool_invocation_arguments() {
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::ToolInvocation {
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
            content: vec![AssistantContent::ToolInvocation {
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
        Message::ToolResult {
            invocation_id: "toolu_01abc".into(),
            content: ToolResultMessageContent::Text("result".into()),
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
            content: vec![AssistantContent::ToolInvocation {
                id: "call_existing".into(),
                name: "test_tool".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::ToolResult {
            invocation_id: "call_existing".into(),
            content: ToolResultMessageContent::Text("ok".into()),
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
                AssistantContent::ToolInvocation {
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
        Message::ToolResult {
            invocation_id: "call_1".into(),
            content: ToolResultMessageContent::Text("file data".into()),
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
    let tools = vec![
        make_tool("test_tool", "Run commands"),
        make_tool("inspect", "Read file"),
    ];
    let result = convert_tools_v2(&tools);

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
    let tools = vec![make_tool("test_tool", "Run primitive host operations")];
    let result = convert_tools_v2(&tools);

    assert_eq!(result.len(), 1);
    match &result[0] {
        ResponsesToolEntry::Function { name, .. } => {
            assert_eq!(name, "test_tool");
        }
    }
}

#[test]
fn convert_tools_v2_json_shape() {
    let tools = vec![make_tool("test_tool", "Run commands")];
    let result = convert_tools_v2(&tools);
    let json = serde_json::to_value(&result).unwrap();
    let arr = json.as_array().unwrap();

    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["type"], "function");
    assert_eq!(arr[0]["name"], "test_tool");
}

#[test]
fn convert_tools_v2_empty_tools() {
    let result = convert_tools_v2(&[]);
    assert!(result.is_empty());
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
