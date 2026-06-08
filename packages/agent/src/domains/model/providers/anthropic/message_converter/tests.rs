use super::super::types::OAUTH_SYSTEM_PROMPT_PREFIX;
use super::*;
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::messages::{Context, Message, UserMessageContent};
use crate::shared::protocol::model_capabilities::{CapabilityParameterSchema, ModelCapability};
use serde_json::Map;

fn simple_context() -> Context {
    Context {
        system_prompt: Some("You are helpful.".into()),
        messages: vec![Message::user("hello")].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    }
}

fn make_tool(name: &str) -> ModelCapability {
    ModelCapability {
        name: name.into(),
        description: format!("{name} tool"),
        parameters: CapabilityParameterSchema {
            schema_type: "object".into(),
            properties: None,
            required: None,
            description: None,
            extra: serde_json::Map::default(),
        },
    }
}

// ── User message conversion ──────────────────────────────────────────

#[test]
fn convert_user_text_message() {
    let content = UserMessageContent::Text("hello".into());
    let param = convert_user_message(&content);
    assert_eq!(param.role, "user");
    assert_eq!(param.content[0]["type"], "text");
    assert_eq!(param.content[0]["text"], "hello");
}

#[test]
fn convert_user_image_block() {
    let content = UserMessageContent::Blocks(vec![
        UserContent::text("describe this"),
        UserContent::image("base64data", "image/png"),
    ]);
    let param = convert_user_message(&content);
    assert_eq!(param.content.len(), 2);
    assert_eq!(param.content[0]["type"], "text");
    assert_eq!(param.content[1]["type"], "image");
    assert_eq!(param.content[1]["source"]["type"], "base64");
    assert_eq!(param.content[1]["source"]["media_type"], "image/png");
}

#[test]
fn convert_user_document_block() {
    let content = UserMessageContent::Blocks(vec![UserContent::Document {
        data: "pdfdata".into(),
        mime_type: "application/pdf".into(),
        file_name: Some("report.pdf".into()),
        extracted_text: None,
    }]);
    let param = convert_user_message(&content);
    assert_eq!(param.content[0]["type"], "document");
    assert_eq!(param.content[0]["source"]["media_type"], "application/pdf");
}

// ── Assistant message conversion ─────────────────────────────────────

#[test]
fn convert_assistant_text_only() {
    let content = vec![AssistantContent::text("response")];
    let id_mapping = HashMap::new();
    let param = convert_assistant_message(&content, &id_mapping);
    assert_eq!(param.role, "assistant");
    assert_eq!(param.content[0]["type"], "text");
    assert_eq!(param.content[0]["text"], "response");
}

#[test]
fn convert_assistant_thinking_with_signature() {
    let content = vec![
        AssistantContent::Thinking {
            thinking: "let me think".into(),
            signature: Some("sig123".into()),
        },
        AssistantContent::text("answer"),
    ];
    let id_mapping = HashMap::new();
    let param = convert_assistant_message(&content, &id_mapping);
    assert_eq!(param.content.len(), 2);
    assert_eq!(param.content[0]["type"], "thinking");
    assert_eq!(param.content[0]["signature"], "sig123");
}

#[test]
fn convert_assistant_thinking_without_signature_filtered() {
    let content = vec![
        AssistantContent::Thinking {
            thinking: "display only".into(),
            signature: None,
        },
        AssistantContent::text("answer"),
    ];
    let id_mapping = HashMap::new();
    let param = convert_assistant_message(&content, &id_mapping);
    // Thinking without signature should be filtered out
    assert_eq!(param.content.len(), 1);
    assert_eq!(param.content[0]["type"], "text");
}

#[test]
fn convert_assistant_capability_invocation() {
    let mut args = Map::new();
    let _ = args.insert("cmd".into(), json!("ls"));
    let content = vec![AssistantContent::CapabilityInvocation {
        id: "toolu_01abc".into(),
        name: "execute".into(),
        arguments: args,
        thought_signature: None,
    }];
    let id_mapping = HashMap::new();
    let param = convert_assistant_message(&content, &id_mapping);
    assert_eq!(param.content[0]["type"], "tool_use");
    assert_eq!(param.content[0]["id"], "toolu_01abc");
    assert_eq!(param.content[0]["name"], "execute");
    assert_eq!(param.content[0]["input"]["cmd"], "ls");
}

#[test]
fn convert_assistant_capability_invocation_remaps_openai_id() {
    let mut args = Map::new();
    let _ = args.insert("cmd".into(), json!("ls"));
    let content = vec![AssistantContent::CapabilityInvocation {
        id: "call_abc123xyz".into(),
        name: "execute".into(),
        arguments: args,
        thought_signature: None,
    }];
    // Build mapping that remaps the OpenAI ID
    let id_mapping = build_invocation_id_mapping(&["call_abc123xyz"], IdFormat::Anthropic);
    let param = convert_assistant_message(&content, &id_mapping);
    let id = param.content[0]["id"].as_str().unwrap();
    assert!(
        id.starts_with("toolu_remap_"),
        "Should remap to Anthropic format: {id}"
    );
}

// ── Capability result conversion ───────────────────────────────────────────

#[test]
fn convert_capability_result_text() {
    let content = CapabilityResultMessageContent::Text("output".into());
    let id_mapping = HashMap::new();
    let param = convert_capability_result("toolu_01abc", &content, None, &id_mapping);
    assert_eq!(param.role, "user");
    assert_eq!(param.content[0]["type"], "tool_result");
    assert_eq!(param.content[0]["tool_use_id"], "toolu_01abc");
    assert_eq!(param.content[0]["content"][0]["text"], "output");
    assert!(param.content[0].get("is_error").is_none());
}

#[test]
fn convert_capability_result_error() {
    let content = CapabilityResultMessageContent::Text("failed".into());
    let id_mapping = HashMap::new();
    let param = convert_capability_result("toolu_01abc", &content, Some(true), &id_mapping);
    assert_eq!(param.content[0]["is_error"], true);
}

#[test]
fn convert_capability_result_with_image() {
    let content = CapabilityResultMessageContent::Blocks(vec![
        CapabilityResultContent::text("screenshot taken"),
        CapabilityResultContent::image("imgdata", "image/png"),
    ]);
    let id_mapping = HashMap::new();
    let param = convert_capability_result("toolu_01abc", &content, None, &id_mapping);
    let inner = &param.content[0]["content"];
    assert_eq!(inner[0]["type"], "text");
    assert_eq!(inner[1]["type"], "image");
    assert_eq!(inner[1]["source"]["media_type"], "image/png");
}

// ── System prompt ────────────────────────────────────────────────────

#[test]
fn system_prompt_no_prefix_returns_cached_blocks() {
    let ctx = simple_context();
    let system = build_system_prompt(&ctx, None);
    assert!(system.is_some());
    let arr = system.unwrap();
    assert!(arr.is_array(), "should return array, not string");
    let blocks = arr.as_array().unwrap();
    // No OAuth prefix block
    assert_ne!(blocks[0]["text"], OAUTH_SYSTEM_PROMPT_PREFIX);
    // Last block has cache_control
    let last = blocks.last().unwrap();
    assert!(last.get("cache_control").is_some());
}

#[test]
fn system_prompt_no_prefix_none_when_empty() {
    let ctx = Context::default();
    let system = build_system_prompt(&ctx, None);
    assert!(system.is_none());
}

#[test]
fn system_prompt_no_prefix_with_volatile_has_two_tiers() {
    let ctx = Context {
        system_prompt: Some("You are helpful.".into()),
        agent_state_context: Some("state".into()),
        ..Default::default()
    };
    let system = build_system_prompt(&ctx, None).unwrap();
    let blocks = system.as_array().unwrap();

    // No OAuth prefix block
    assert_ne!(blocks[0]["text"], OAUTH_SYSTEM_PROMPT_PREFIX);

    // Should have cache_control with 1h on last stable, 5m on last volatile
    let has_1h = blocks
        .iter()
        .any(|b| b["cache_control"]["ttl"].as_str() == Some("1h"));
    let has_default = blocks.iter().any(|b| {
        b.get("cache_control").is_some()
            && (b["cache_control"].get("ttl").is_none() || b["cache_control"]["ttl"].is_null())
    });
    assert!(has_1h, "Should have 1h cache on stable content");
    assert!(
        has_default,
        "Should have default (5m) cache on volatile content"
    );
}

#[test]
fn system_prompt_with_prefix_returns_array() {
    let ctx = simple_context();
    let system = build_system_prompt(&ctx, Some(OAUTH_SYSTEM_PROMPT_PREFIX));
    assert!(system.is_some());
    let arr = system.unwrap();
    assert!(arr.is_array());
    let blocks = arr.as_array().unwrap();
    // First block is the OAuth prefix
    assert_eq!(blocks[0]["text"], OAUTH_SYSTEM_PROMPT_PREFIX);
}

#[test]
fn system_prompt_with_prefix_has_cache_control() {
    let ctx = Context {
        system_prompt: Some("You are helpful.".into()),
        ..Default::default()
    };
    let system = build_system_prompt(&ctx, Some(OAUTH_SYSTEM_PROMPT_PREFIX)).unwrap();
    let blocks = system.as_array().unwrap();
    // Last block should have cache_control
    let last = blocks.last().unwrap();
    assert!(last.get("cache_control").is_some());
}

#[test]
fn system_prompt_with_prefix_volatile_has_two_cache_tiers() {
    let ctx = Context {
        system_prompt: Some("You are helpful.".into()),
        agent_state_context: Some("state".into()),
        ..Default::default()
    };
    let system = build_system_prompt(&ctx, Some(OAUTH_SYSTEM_PROMPT_PREFIX)).unwrap();
    let blocks = system.as_array().unwrap();

    // Should have cache_control with 1h on last stable, 5m on last volatile
    let has_1h = blocks
        .iter()
        .any(|b| b["cache_control"]["ttl"].as_str() == Some("1h"));
    let has_default = blocks.iter().any(|b| {
        b.get("cache_control").is_some()
            && (b["cache_control"].get("ttl").is_none() || b["cache_control"]["ttl"].is_null())
    });
    assert!(has_1h, "Should have 1h cache on stable content");
    assert!(
        has_default,
        "Should have default (5m) cache on volatile content"
    );
}

// ── ModelCapability conversion ──────────────────────────────────────────────────

#[test]
fn convert_tools_always_caches_last() {
    let capabilities = vec![make_tool("execute"), make_tool("inspect")];
    let result = convert_tools(&capabilities);
    assert_eq!(result.len(), 2);
    assert_eq!(result[0].name, "execute");
    assert_eq!(result[1].name, "inspect");
    assert!(result[0].cache_control.is_none());
    assert!(result[1].cache_control.is_some());
    assert_eq!(
        result[1].cache_control.as_ref().unwrap().ttl.as_deref(),
        Some("1h")
    );
}

#[test]
fn convert_tools_empty() {
    let capabilities: Vec<ModelCapability> = vec![];
    let result = convert_tools(&capabilities);
    assert!(result.is_empty());
}

// ── Full context conversion ──────────────────────────────────────────

#[test]
fn convert_context_full() {
    let ctx = Context {
        system_prompt: Some("You are helpful.".into()),
        messages: vec![
            Message::user("hello"),
            Message::Assistant {
                content: vec![AssistantContent::text("hi there")],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ]
        .into(),
        capabilities: Some(vec![make_tool("execute")]),
        ..Default::default()
    };

    let (system, messages, capabilities) = convert_context(&ctx, Some(OAUTH_SYSTEM_PROMPT_PREFIX));
    assert!(system.is_some());
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0].role, "user");
    assert_eq!(messages[1].role, "assistant");
    assert!(capabilities.is_some());
    assert_eq!(capabilities.unwrap().len(), 1);
}

// ── ID mapping ───────────────────────────────────────────────────────

#[test]
fn build_id_mapping_from_messages() {
    let messages = vec![
        Message::user("hi"),
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_abc123def456".into(),
                name: "execute".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
    ];
    let mapping = build_id_mapping(&messages);
    // OpenAI-format ID should get a mapping entry
    assert!(!mapping.is_empty());
}

#[test]
fn build_id_mapping_empty_for_anthropic_ids() {
    let messages = vec![
        Message::user("hi"),
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01abc".into(),
                name: "execute".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
    ];
    let mapping = build_id_mapping(&messages);
    // Anthropic-format IDs don't need remapping
    assert!(mapping.is_empty());
}

// ── dedup_tool_blocks ──────────────────────────────────────────────

#[test]
fn dedup_assistant_capability_invocation_keeps_last() {
    let messages = vec![AnthropicMessageParam {
        role: "assistant".into(),
        content: vec![
            json!({"type": "tool_use", "id": "toolu_remap_1", "name": "execute", "input": {"cmd": "echo old"}}),
            json!({"type": "text", "text": "thinking..."}),
            json!({"type": "tool_use", "id": "toolu_remap_1", "name": "execute", "input": {"cmd": "echo new"}}),
        ],
    }];
    let deduped = dedup_tool_blocks(messages);
    assert_eq!(deduped[0].content.len(), 2);
    assert_eq!(deduped[0].content[0]["type"], "text");
    assert_eq!(deduped[0].content[1]["id"], "toolu_remap_1");
    assert_eq!(deduped[0].content[1]["input"]["cmd"], "echo new");
}

#[test]
fn dedup_user_capability_result_keeps_last() {
    let messages = vec![AnthropicMessageParam {
        role: "user".into(),
        content: vec![
            json!({"type": "tool_result", "tool_use_id": "toolu_remap_1", "content": [{"type": "text", "text": "old result"}]}),
            json!({"type": "tool_result", "tool_use_id": "toolu_remap_1", "content": [{"type": "text", "text": "new result"}]}),
            json!({"type": "tool_result", "tool_use_id": "toolu_remap_2", "content": [{"type": "text", "text": "unique"}]}),
        ],
    }];
    let deduped = dedup_tool_blocks(messages);
    assert_eq!(deduped[0].content.len(), 2);
    assert_eq!(deduped[0].content[0]["tool_use_id"], "toolu_remap_1");
    assert_eq!(deduped[0].content[0]["content"][0]["text"], "new result");
    assert_eq!(deduped[0].content[1]["tool_use_id"], "toolu_remap_2");
}

#[test]
fn dedup_no_duplicates_unchanged() {
    let messages = vec![
        AnthropicMessageParam {
            role: "assistant".into(),
            content: vec![
                json!({"type": "tool_use", "id": "toolu_1", "name": "a", "input": {}}),
                json!({"type": "tool_use", "id": "toolu_2", "name": "b", "input": {}}),
            ],
        },
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "tool_result", "tool_use_id": "toolu_1", "content": []}),
                json!({"type": "tool_result", "tool_use_id": "toolu_2", "content": []}),
            ],
        },
    ];
    let deduped = dedup_tool_blocks(messages);
    assert_eq!(deduped[0].content.len(), 2);
    assert_eq!(deduped[1].content.len(), 2);
}

// ── merge_consecutive_roles ─────────────────────────────────────────

#[test]
fn merge_consecutive_user_messages() {
    let messages = vec![
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "tool_result", "tool_use_id": "tc-1", "content": [{"type": "text", "text": "out1"}]}),
            ],
        },
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "tool_result", "tool_use_id": "tc-2", "content": [{"type": "text", "text": "out2"}]}),
            ],
        },
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![
                json!({"type": "tool_result", "tool_use_id": "tc-3", "content": [{"type": "text", "text": "out3"}]}),
            ],
        },
    ];
    let merged = merge_consecutive_roles(messages);
    assert_eq!(merged.len(), 1);
    assert_eq!(merged[0].role, "user");
    assert_eq!(merged[0].content.len(), 3);
}

#[test]
fn merge_preserves_alternating_roles() {
    let messages = vec![
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![json!({"type": "text", "text": "hello"})],
        },
        AnthropicMessageParam {
            role: "assistant".into(),
            content: vec![json!({"type": "text", "text": "hi"})],
        },
        AnthropicMessageParam {
            role: "user".into(),
            content: vec![json!({"type": "text", "text": "bye"})],
        },
    ];
    let merged = merge_consecutive_roles(messages);
    assert_eq!(merged.len(), 3);
}

#[test]
fn merge_empty_input() {
    let merged = merge_consecutive_roles(vec![]);
    assert!(merged.is_empty());
}

// ── Full flow: capability results merge into single user message ──────────

#[test]
fn full_flow_multiple_capability_results_become_single_user_message() {
    let mut args = Map::new();
    let _ = args.insert("cmd".into(), json!("ls"));
    let messages = vec![
        Message::user("do three things"),
        Message::Assistant {
            content: vec![
                AssistantContent::CapabilityInvocation {
                    id: "toolu_01a".into(),
                    name: "execute".into(),
                    arguments: args.clone(),
                    thought_signature: None,
                },
                AssistantContent::CapabilityInvocation {
                    id: "toolu_01b".into(),
                    name: "inspect".into(),
                    arguments: args.clone(),
                    thought_signature: None,
                },
                AssistantContent::CapabilityInvocation {
                    id: "toolu_01c".into(),
                    name: "search".into(),
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
            invocation_id: "toolu_01a".into(),
            content: crate::shared::protocol::messages::CapabilityResultMessageContent::Text(
                "out1".into(),
            ),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01b".into(),
            content: crate::shared::protocol::messages::CapabilityResultMessageContent::Text(
                "out2".into(),
            ),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01c".into(),
            content: crate::shared::protocol::messages::CapabilityResultMessageContent::Text(
                "out3".into(),
            ),
            is_error: None,
        },
    ];
    let converted = convert_messages(&messages);
    // Should be: user, assistant, user (3 tool_result blocks merged)
    assert_eq!(converted.len(), 3);
    assert_eq!(converted[0].role, "user");
    assert_eq!(converted[1].role, "assistant");
    assert_eq!(converted[2].role, "user");
    // The merged user message has 3 Anthropic tool_result content blocks.
    assert_eq!(converted[2].content.len(), 3);
    assert_eq!(converted[2].content[0]["type"], "tool_result");
    assert_eq!(converted[2].content[1]["type"], "tool_result");
    assert_eq!(converted[2].content[2]["type"], "tool_result");
}

// ── End-to-end: cross-provider duplicate result dedup ────────────────────

#[test]
fn full_flow_duplicate_openai_capability_results_deduped_after_remap() {
    // Simulates OpenAI-format IDs plus duplicate capability results from DB.
    let mut args = Map::new();
    let _ = args.insert("command".into(), json!("ls"));
    let messages = vec![
        Message::user("run something"),
        Message::Assistant {
            content: vec![
                AssistantContent::CapabilityInvocation {
                    id: "call_abc123".into(),
                    name: "execute".into(),
                    arguments: args.clone(),
                    thought_signature: None,
                },
                AssistantContent::CapabilityInvocation {
                    id: "call_def456".into(),
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
        // Duplicate capability results from DB (same invocation_id executed twice).
        Message::CapabilityResult {
            invocation_id: "call_abc123".into(),
            content: CapabilityResultMessageContent::Text("first execution".into()),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "call_abc123".into(),
            content: CapabilityResultMessageContent::Text("second execution".into()),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "call_def456".into(),
            content: CapabilityResultMessageContent::Text("read output".into()),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "call_def456".into(),
            content: CapabilityResultMessageContent::Text("read output dup".into()),
            is_error: None,
        },
    ];
    let converted = convert_messages(&messages);
    // user, assistant, user (merged tool_result blocks)
    assert_eq!(converted.len(), 3);
    assert_eq!(converted[2].role, "user");
    // Should have exactly 2 tool_result blocks (one per unique ID), not 4.
    assert_eq!(
        converted[2].content.len(),
        2,
        "duplicate capability results should be deduped to one per tool_use_id"
    );
    // Both should be Anthropic tool_result blocks.
    assert_eq!(converted[2].content[0]["type"], "tool_result");
    assert_eq!(converted[2].content[1]["type"], "tool_result");
    // Verify IDs were remapped (OpenAI → Anthropic format)
    let id0 = converted[2].content[0]["tool_use_id"].as_str().unwrap();
    let id1 = converted[2].content[1]["tool_use_id"].as_str().unwrap();
    assert!(id0.starts_with("toolu_remap_"), "should be remapped: {id0}");
    assert!(id1.starts_with("toolu_remap_"), "should be remapped: {id1}");
    assert_ne!(id0, id1, "two distinct tool_use_id values");
}
