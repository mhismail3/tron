use super::*;
use serde_json::json;

#[test]
fn convert_simple_text_user_message() {
    let messages = vec![Message::user("Hello")];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].role, "user");
    assert_eq!(result[0].content, Some("Hello".into()));
}

#[test]
fn multi_block_user_message_serializes_native_content_as_string() {
    let messages = vec![Message::User {
        content: UserMessageContent::Blocks(vec![
            UserContent::Text {
                text: "Compacted summary".into(),
            },
            UserContent::Document {
                file_name: Some("scorecard.md".into()),
                data: String::new(),
                mime_type: "text/markdown".into(),
                extracted_text: Some("Scenario evidence".into()),
            },
        ]),
        timestamp: None,
    }];

    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    assert!(
        wire["content"].is_string(),
        "Ollama content must be a string"
    );
    assert!(
        wire["content"]
            .as_str()
            .unwrap()
            .contains("Compacted summary")
    );
    assert!(wire["content"].as_str().unwrap().contains("scorecard.md"));
    assert!(wire.get("images").is_none());
}

#[test]
fn image_user_message_uses_native_images_field() {
    let messages = vec![Message::User {
        content: UserMessageContent::Blocks(vec![
            UserContent::Text {
                text: "Describe this image".into(),
            },
            UserContent::Image {
                data: "base64data".into(),
                mime_type: "image/png".into(),
            },
        ]),
        timestamp: None,
    }];

    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    assert_eq!(wire["content"], "Describe this image");
    assert_eq!(wire["images"][0], "base64data");
}

#[test]
fn convert_assistant_with_text() {
    let messages = vec![Message::assistant("Hi there")];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].role, "assistant");
    assert_eq!(result[0].content, Some("Hi there".into()));
    assert!(result[0].tool_calls.is_none());
}

#[test]
fn convert_assistant_with_tool_calls() {
    let mut args = serde_json::Map::new();
    let _ = args.insert("path".into(), json!("/tmp/test"));
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "toolu_abc123".into(),
            name: "read_file".into(),
            arguments: args,
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].role, "assistant");
    let wire = serde_json::to_value(&result[0]).unwrap();
    assert!(wire["tool_calls"].is_array());
    assert!(wire.get("capability_invocations").is_none());
    let tc = result[0].tool_calls.as_ref().unwrap();
    assert_eq!(tc.len(), 1);
    assert_eq!(tc[0].function.name, "read_file");
    assert!(tc[0].id.starts_with("call_"));
    // Native Ollama API: arguments must be a JSON object, not a string
    assert_eq!(tc[0].function.arguments, json!({"path": "/tmp/test"}));
}

#[test]
fn convert_assistant_thinking_blocks_skipped() {
    let messages = vec![Message::Assistant {
        content: vec![
            AssistantContent::Thinking {
                thinking: "Let me think...".into(),
                signature: None,
            },
            AssistantContent::text("The answer is 42"),
        ],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].content, Some("The answer is 42".into()));
}

#[test]
fn convert_empty_assistant_skipped() {
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::Thinking {
            thinking: "hmm".into(),
            signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 0);
}

#[test]
fn convert_capability_result_message() {
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_xyz".into(),
                name: "execute".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_xyz".into(),
            content: CapabilityResultMessageContent::Text("command output".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 2);
    assert_eq!(result[1].role, "tool");
    assert_eq!(result[1].content, Some("command output".into()));
    // Native Ollama API: tool results use tool_name, not invocation_id
    assert_eq!(result[1].tool_name, Some("execute".into()));
}

#[test]
fn convert_tools_to_chat_format() {
    let capabilities = vec![ModelCapability {
        name: "get_weather".into(),
        description: "Get weather info".into(),
        parameters: serde_json::from_value(json!({
            "type": "object",
            "properties": {
                "location": {"type": "string"}
            },
            "required": ["location"]
        }))
        .unwrap(),
    }];
    let result = convert_tools(&capabilities);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].tool_type, "function");
    assert_eq!(result[0].function.name, "get_weather");
    assert_eq!(result[0].function.description, "Get weather info");
}

#[test]
fn convert_document_with_text() {
    let block = UserContent::Document {
        file_name: Some("readme.md".into()),
        data: String::new(),
        mime_type: "text/markdown".into(),
        extracted_text: Some("# Hello".into()),
    };
    let ConvertedUserBlock::Text(text) = convert_user_block(&block, true) else {
        panic!("document should flatten to text");
    };
    assert!(text.contains("readme.md"));
    assert!(text.contains("# Hello"));
}

#[test]
fn convert_document_without_text() {
    let block = UserContent::Document {
        file_name: Some("data.pdf".into()),
        data: String::new(),
        mime_type: "application/pdf".into(),
        extracted_text: None,
    };
    let ConvertedUserBlock::Text(text) = convert_user_block(&block, true) else {
        panic!("document should flatten to text");
    };
    assert!(text.contains("content not available"));
}

#[test]
fn image_block_skipped_when_not_supported() {
    let block = UserContent::Image {
        data: "base64data".into(),
        mime_type: "image/png".into(),
    };
    assert!(matches!(
        convert_user_block(&block, false),
        ConvertedUserBlock::None
    ));
}

#[test]
fn image_block_converted_when_supported() {
    let block = UserContent::Image {
        data: "base64data".into(),
        mime_type: "image/png".into(),
    };
    let ConvertedUserBlock::Image(data) = convert_user_block(&block, true) else {
        panic!("image should convert to native Ollama image bytes");
    };
    assert_eq!(data, "base64data");
}

#[test]
fn mixed_text_and_tool_calls_preserved() {
    let mut args = serde_json::Map::new();
    let _ = args.insert("q".into(), json!("test"));
    let messages = vec![Message::Assistant {
        content: vec![
            AssistantContent::text("Let me search for that."),
            AssistantContent::CapabilityInvocation {
                id: "toolu_1".into(),
                name: "search".into(),
                arguments: args,
                thought_signature: None,
            },
        ],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert!(result[0].content.is_some());
    assert!(result[0].tool_calls.is_some());
    assert_eq!(result[0].tool_calls.as_ref().unwrap().len(), 1);
}

// ── Phase 1: Arguments serialize as JSON objects ─────────────────────

#[test]
fn capability_invocation_arguments_serialize_as_object() {
    let mut args = serde_json::Map::new();
    let _ = args.insert("command".into(), json!("echo hello"));
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "toolu_01".into(),
            name: "execute".into(),
            arguments: args,
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);

    // Serialize the whole message to JSON and verify arguments is an object
    let wire = serde_json::to_value(&result[0]).unwrap();
    let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
    assert!(
        wire_args.is_object(),
        "arguments must be a JSON object on the wire, got: {wire_args}"
    );
    assert_eq!(wire_args["command"], "echo hello");
}

#[test]
fn capability_invocation_empty_arguments_serialize_as_object() {
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "toolu_01".into(),
            name: "execute".into(),
            arguments: serde_json::Map::new(),
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
    assert!(wire_args.is_object());
    assert_eq!(wire_args.as_object().unwrap().len(), 0);
}

#[test]
fn capability_invocation_nested_arguments_serialize_as_object() {
    let mut args = serde_json::Map::new();
    let _ = args.insert(
        "config".into(),
        json!({"key": "value", "nested": {"deep": true}}),
    );
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "call_abc".into(),
            name: "configure".into(),
            arguments: args,
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
    assert!(wire_args.is_object());
    assert_eq!(wire_args["config"]["nested"]["deep"], true);
}

#[test]
fn capability_invocation_arguments_with_special_chars() {
    let mut args = serde_json::Map::new();
    let _ = args.insert(
        "command".into(),
        json!("echo \"hello\\nworld\" | grep 'test'"),
    );
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "toolu_01".into(),
            name: "execute".into(),
            arguments: args,
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    let wire_args = &wire["tool_calls"][0]["function"]["arguments"];
    assert!(wire_args.is_object());
    assert_eq!(wire_args["command"], "echo \"hello\\nworld\" | grep 'test'");
}

#[test]
fn multiple_tool_calls_arguments_all_objects() {
    let mut args1 = serde_json::Map::new();
    let _ = args1.insert("path".into(), json!("/tmp/a"));
    let mut args2 = serde_json::Map::new();
    let _ = args2.insert("path".into(), json!("/tmp/b"));
    let messages = vec![Message::Assistant {
        content: vec![
            AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "inspect".into(),
                arguments: args1,
                thought_signature: None,
            },
            AssistantContent::CapabilityInvocation {
                id: "toolu_02".into(),
                name: "inspect".into(),
                arguments: args2,
                thought_signature: None,
            },
        ],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[0]).unwrap();
    for (i, tc) in wire["tool_calls"].as_array().unwrap().iter().enumerate() {
        assert!(
            tc["function"]["arguments"].is_object(),
            "capability_invocation[{i}] arguments must be a JSON object"
        );
    }
}

// ── Phase 2: Tool results use tool_name ─────────────────────────────

#[test]
fn capability_result_has_tool_name() {
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "execute".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01".into(),
            content: CapabilityResultMessageContent::Text("ok".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    let wire = serde_json::to_value(&result[1]).unwrap();
    assert_eq!(wire["tool_name"], "execute");
    assert!(wire.get("invocation_id").is_none());
    assert!(wire.get("model_primitive_name").is_none());
}

#[test]
fn capability_result_after_provider_switch() {
    // Anthropic-origin IDs (toolu_*) must still resolve to tool_name
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01abc".into(),
                name: "read_file".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01abc".into(),
            content: CapabilityResultMessageContent::Text("file contents".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result[1].tool_name, Some("read_file".into()));
}

#[test]
fn capability_result_with_blocks_content() {
    use crate::shared::protocol::content::CapabilityResultContent;
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_abc".into(),
                name: "search".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "call_abc".into(),
            content: CapabilityResultMessageContent::Blocks(vec![
                CapabilityResultContent::text("line1"),
                CapabilityResultContent::text("line2"),
            ]),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result[1].tool_name, Some("search".into()));
    assert_eq!(result[1].content, Some("line1\nline2".into()));
}

#[test]
fn capability_result_with_is_error_still_converts() {
    // is_error is silently dropped (Ollama native API doesn't support it)
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_err".into(),
                name: "execute".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_err".into(),
            content: CapabilityResultMessageContent::Text("Error: permission denied".into()),
            is_error: Some(true),
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result[1].role, "tool");
    assert_eq!(result[1].tool_name, Some("execute".into()));
    assert_eq!(result[1].content, Some("Error: permission denied".into()));
}

#[test]
fn full_roundtrip_conversation() {
    // Full conversation: user → assistant+capability_invocation → capability_result
    let mut args = serde_json::Map::new();
    let _ = args.insert("command".into(), json!("echo hello"));
    let messages = vec![
        Message::user("Run a command for me"),
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "execute".into(),
                arguments: args,
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01".into(),
            content: CapabilityResultMessageContent::Text("hello".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 3);

    // Serialize full conversation to verify wire format
    let wire: Vec<Value> = result
        .iter()
        .map(|m| serde_json::to_value(m).unwrap())
        .collect();

    // User message
    assert_eq!(wire[0]["role"], "user");

    // Assistant message with tool call — arguments is an object
    assert_eq!(wire[1]["role"], "assistant");
    assert!(wire[1]["tool_calls"][0]["function"]["arguments"].is_object());
    assert!(wire[1].get("capability_invocations").is_none());
    assert_eq!(
        wire[1]["tool_calls"][0]["function"]["arguments"]["command"],
        "echo hello"
    );

    // Tool result — uses tool_name, no invocation_id
    assert_eq!(wire[2]["role"], "tool");
    assert_eq!(wire[2]["tool_name"], "execute");
    assert_eq!(wire[2]["content"], "hello");
    assert!(wire[2].get("invocation_id").is_none());
    assert!(wire[2].get("model_primitive_name").is_none());
}

#[test]
fn multiple_tool_calls_multiple_results() {
    let mut args1 = serde_json::Map::new();
    let _ = args1.insert("path".into(), json!("/a"));
    let mut args2 = serde_json::Map::new();
    let _ = args2.insert("command".into(), json!("ls"));
    let messages = vec![
        Message::Assistant {
            content: vec![
                AssistantContent::CapabilityInvocation {
                    id: "toolu_01".into(),
                    name: "read_file".into(),
                    arguments: args1,
                    thought_signature: None,
                },
                AssistantContent::CapabilityInvocation {
                    id: "toolu_02".into(),
                    name: "execute".into(),
                    arguments: args2,
                    thought_signature: None,
                },
            ],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_01".into(),
            content: CapabilityResultMessageContent::Text("file contents".into()),
            is_error: None,
        },
        Message::CapabilityResult {
            invocation_id: "toolu_02".into(),
            content: CapabilityResultMessageContent::Text("dir listing".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 3);
    assert_eq!(result[1].tool_name, Some("read_file".into()));
    assert_eq!(result[2].tool_name, Some("execute".into()));
}

#[test]
fn capability_result_orphaned_id_unknown_marker() {
    // ToolResult with no matching assistant tool call → mark as "unknown".
    let messages = vec![Message::CapabilityResult {
        invocation_id: "orphan_id".into(),
        content: CapabilityResultMessageContent::Text("result".into()),
        is_error: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result[0].tool_name, Some("unknown".into()));
}

// ── Phase 3: Edge case verification ─────────────────────────────────

#[test]
fn assistant_only_tool_calls_no_text() {
    let messages = vec![Message::Assistant {
        content: vec![AssistantContent::CapabilityInvocation {
            id: "call_abc".into(),
            name: "execute".into(),
            arguments: serde_json::Map::new(),
            thought_signature: None,
        }],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    assert!(result[0].content.is_none());
    assert!(result[0].tool_calls.is_some());
}

#[test]
fn assistant_thinking_text_and_tool_calls() {
    let mut args = serde_json::Map::new();
    let _ = args.insert("q".into(), json!("rust"));
    let messages = vec![Message::Assistant {
        content: vec![
            AssistantContent::Thinking {
                thinking: "Let me plan this...".into(),
                signature: None,
            },
            AssistantContent::text("I'll search for that."),
            AssistantContent::CapabilityInvocation {
                id: "toolu_01".into(),
                name: "search".into(),
                arguments: args,
                thought_signature: None,
            },
        ],
        usage: None,
        cost: None,
        stop_reason: None,
        thinking: None,
    }];
    let result = convert_messages(&messages, true);
    assert_eq!(result.len(), 1);
    // Thinking is dropped
    assert_eq!(result[0].content, Some("I'll search for that.".into()));
    // Tool call preserved with object arguments
    let tc = result[0].tool_calls.as_ref().unwrap();
    assert_eq!(tc[0].function.name, "search");
    assert_eq!(tc[0].function.arguments, json!({"q": "rust"}));
}

#[test]
fn invocation_id_already_openai_format() {
    // IDs already in OpenAI format → no remapping needed, tool_name still resolves
    let messages = vec![
        Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_already_openai".into(),
                name: "execute".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
        Message::CapabilityResult {
            invocation_id: "call_already_openai".into(),
            content: CapabilityResultMessageContent::Text("done".into()),
            is_error: None,
        },
    ];
    let result = convert_messages(&messages, true);
    // ID passed through unchanged
    assert_eq!(
        result[0].tool_calls.as_ref().unwrap()[0].id,
        "call_already_openai"
    );
    // tool_name still resolved correctly
    assert_eq!(result[1].tool_name, Some("execute".into()));
}
