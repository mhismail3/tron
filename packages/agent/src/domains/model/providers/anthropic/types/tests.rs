use super::*;

fn assert_float_eq(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < f64::EPSILON,
        "expected {expected}, got {actual}"
    );
}

// -- Model registry --

#[test]
fn get_claude_model_opus_46() {
    let info = get_claude_model("claude-opus-4-6").unwrap();
    assert_eq!(info.name, "Claude Opus 4.6");
    assert_eq!(info.context_window, 1_000_000);
    assert_eq!(info.max_output, 128_000);
    assert!(info.supports_thinking);
    assert!(!info.supports_thinking_beta_headers);
    assert!(info.supports_adaptive_thinking);
    assert!(info.supports_effort);
    assert!(info.supports_capabilities);
    // 4.6 is no longer the recommended Opus (4.7 took the spot).
    assert!(!info.recommended);
    assert!(!info.retired_generation);
}

#[test]
fn get_claude_model_sonnet_46() {
    let info = get_claude_model("claude-sonnet-4-6").unwrap();
    assert_eq!(info.name, "Claude Sonnet 4.6");
    assert_eq!(info.context_window, 1_000_000);
    assert_eq!(info.max_output, 64_000);
    assert!(info.supports_thinking);
    assert!(!info.supports_thinking_beta_headers);
    assert!(info.supports_adaptive_thinking);
    assert!(info.supports_effort);
    assert!(info.supports_capabilities);
    assert_float_eq(info.input_cost_per_million, 3.0);
    assert_float_eq(info.output_cost_per_million, 15.0);
    assert_float_eq(info.cache_read_cost_per_million, 0.3);
    assert!(info.recommended);
    assert!(!info.retired_generation);
}

#[test]
fn get_claude_model_opus_45() {
    let info = get_claude_model("claude-opus-4-5-20251101").unwrap();
    assert_eq!(info.short_name, "Opus 4.5");
    assert!(info.supports_thinking);
    assert!(info.supports_thinking_beta_headers);
    assert!(!info.supports_adaptive_thinking);
    assert!(!info.supports_effort);
    assert_eq!(info.max_output, 64_000);
}

#[test]
fn get_claude_model_sonnet_45() {
    let info = get_claude_model("claude-sonnet-4-5-20250929").unwrap();
    assert_eq!(info.short_name, "Sonnet 4.5");
    assert!(info.supports_thinking);
    assert!(info.supports_thinking_beta_headers);
    assert!(!info.supports_adaptive_thinking);
    assert!(!info.supports_effort);
}

#[test]
fn get_claude_model_opus_41_is_opus_not_sonnet() {
    let info = get_claude_model("claude-opus-4-1-20250805").unwrap();
    assert_eq!(info.name, "Claude Opus 4.1");
    assert_eq!(info.short_name, "Opus 4.1");
    assert_eq!(info.max_output, 32_000);
    assert_float_eq(info.input_cost_per_million, 15.0);
    assert!(info.retired_generation);
}

#[test]
fn get_claude_model_haiku_3_retired_generation() {
    let info = get_claude_model("claude-3-haiku-20240307").unwrap();
    assert_eq!(info.max_output, 4_096);
    assert!(!info.supports_thinking);
    assert!(info.retired_generation);
}

#[test]
fn get_claude_model_unknown_returns_none() {
    assert!(get_claude_model("gpt-5").is_none());
}

#[test]
fn all_claude_model_ids_contains_expected() {
    let ids = all_claude_model_ids();
    assert!(ids.contains(&"claude-opus-4-7"));
    assert!(ids.contains(&"claude-opus-4-6"));
    assert!(ids.contains(&"claude-sonnet-4-6"));
    assert!(ids.contains(&"claude-opus-4-5-20251101"));
    assert!(ids.contains(&"claude-sonnet-4-5-20250929"));
    assert!(ids.contains(&"claude-3-haiku-20240307"));
    assert_eq!(ids.len(), 11); // 11 models total
}

// -- SystemPromptBlock --

#[test]
fn system_prompt_block_text_no_cache() {
    let block = SystemPromptBlock::text("hello");
    let json = serde_json::to_value(&block).unwrap();
    assert_eq!(json["type"], "text");
    assert_eq!(json["text"], "hello");
    assert!(json.get("cache_control").is_none());
}

#[test]
fn system_prompt_block_cached_5m() {
    let block = SystemPromptBlock::text_cached("hello", Some("5m"));
    let json = serde_json::to_value(&block).unwrap();
    assert_eq!(json["cache_control"]["type"], "ephemeral");
    assert_eq!(json["cache_control"]["ttl"], "5m");
}

#[test]
fn system_prompt_block_cached_no_ttl() {
    let block = SystemPromptBlock::text_cached("hello", None);
    let json = serde_json::to_value(&block).unwrap();
    assert_eq!(json["cache_control"]["type"], "ephemeral");
    assert!(json["cache_control"].get("ttl").is_none());
}

// -- SSE event deserialization --

#[test]
fn sse_message_start() {
    let json = r#"{
            "type": "message_start",
            "message": {
                "id": "msg_01XaBC",
                "model": "claude-opus-4-6",
                "stop_reason": null,
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 20
                }
            }
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::MessageStart { message } => {
            assert_eq!(message.id.as_deref(), Some("msg_01XaBC"));
            assert_eq!(message.usage.input_tokens, 100);
            assert_eq!(message.usage.cache_creation_input_tokens, 50);
            assert_eq!(message.usage.cache_read_input_tokens, 20);
        }
        _ => panic!("expected MessageStart"),
    }
}

#[test]
fn sse_message_start_with_cache_creation_breakdown() {
    let json = r#"{
            "type": "message_start",
            "message": {
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 80,
                    "cache_read_input_tokens": 20,
                    "cache_creation": {
                        "ephemeral_5m_input_tokens": 30,
                        "ephemeral_1h_input_tokens": 50
                    }
                }
            }
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::MessageStart { message } => {
            let cc = message.usage.cache_creation.unwrap();
            assert_eq!(cc.ephemeral_5m_input_tokens, 30);
            assert_eq!(cc.ephemeral_1h_input_tokens, 50);
        }
        _ => panic!("expected MessageStart"),
    }
}

#[test]
fn sse_content_block_start_text() {
    let json = r#"{
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockStart {
            index,
            content_block,
        } => {
            assert_eq!(index, 0);
            assert!(matches!(content_block, SseContentBlock::Text { .. }));
        }
        _ => panic!("expected ContentBlockStart"),
    }
}

#[test]
fn sse_content_block_start_thinking() {
    let json = r#"{
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": ""}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockStart { content_block, .. } => {
            assert!(matches!(content_block, SseContentBlock::Thinking { .. }));
        }
        _ => panic!("expected ContentBlockStart"),
    }
}

#[test]
fn sse_content_block_start_tool_use() {
    let json = r#"{
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "tool_use", "id": "toolu_01abc", "name": "execute", "input": {}}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockStart { content_block, .. } => match content_block {
            SseContentBlock::CapabilityInvocation { id, name } => {
                assert_eq!(id, "toolu_01abc");
                assert_eq!(name, "execute");
            }
            _ => panic!("expected CapabilityInvocation"),
        },
        _ => panic!("expected ContentBlockStart"),
    }
}

#[test]
fn sse_content_block_delta_text() {
    let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "Hello"}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockDelta { delta, .. } => match delta {
            SseDelta::TextDelta { text } => assert_eq!(text, "Hello"),
            _ => panic!("expected TextDelta"),
        },
        _ => panic!("expected ContentBlockDelta"),
    }
}

#[test]
fn sse_content_block_delta_thinking() {
    let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "Let me consider"}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockDelta { delta, .. } => match delta {
            SseDelta::ThinkingDelta { thinking } => {
                assert_eq!(thinking, "Let me consider");
            }
            _ => panic!("expected ThinkingDelta"),
        },
        _ => panic!("expected ContentBlockDelta"),
    }
}

#[test]
fn sse_content_block_delta_signature() {
    let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "sig123"}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockDelta { delta, .. } => match delta {
            SseDelta::SignatureDelta { signature } => {
                assert_eq!(signature, "sig123");
            }
            _ => panic!("expected SignatureDelta"),
        },
        _ => panic!("expected ContentBlockDelta"),
    }
}

#[test]
fn sse_content_block_delta_input_json() {
    let json = r#"{
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "input_json_delta", "partial_json": "{\"cmd\":\"ls\"}"}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::ContentBlockDelta { delta, .. } => match delta {
            SseDelta::InputJsonDelta { partial_json } => {
                assert_eq!(partial_json, r#"{"cmd":"ls"}"#);
            }
            _ => panic!("expected InputJsonDelta"),
        },
        _ => panic!("expected ContentBlockDelta"),
    }
}

#[test]
fn sse_message_delta() {
    let json = r#"{
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 42}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::MessageDelta { delta, usage } => {
            assert_eq!(delta.stop_reason.as_deref(), Some("end_turn"));
            assert_eq!(usage.unwrap().output_tokens, 42);
        }
        _ => panic!("expected MessageDelta"),
    }
}

#[test]
fn sse_message_stop() {
    let json = r#"{"type": "message_stop"}"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    assert!(matches!(event, AnthropicSseEvent::MessageStop));
}

#[test]
fn sse_ping() {
    let json = r#"{"type": "ping"}"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    assert!(matches!(event, AnthropicSseEvent::Ping));
}

#[test]
fn sse_error() {
    let json = r#"{
            "type": "error",
            "error": {"type": "overloaded_error", "message": "Server overloaded"}
        }"#;
    let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
    match event {
        AnthropicSseEvent::Error { error } => {
            assert_eq!(error.error_type, "overloaded_error");
            assert_eq!(error.message, "Server overloaded");
        }
        _ => panic!("expected Error"),
    }
}

// -- Request building helpers --

#[test]
fn text_block_builds_correct_json() {
    let block = text_block("hello");
    assert_eq!(block["type"], "text");
    assert_eq!(block["text"], "hello");
}

#[test]
fn image_block_builds_correct_json() {
    let block = image_block("base64data", "image/png");
    assert_eq!(block["type"], "image");
    assert_eq!(block["source"]["type"], "base64");
    assert_eq!(block["source"]["media_type"], "image/png");
    assert_eq!(block["source"]["data"], "base64data");
}

#[test]
fn document_block_builds_correct_json() {
    let block = document_block("pdfdata", "application/pdf");
    assert_eq!(block["type"], "document");
    assert_eq!(block["source"]["media_type"], "application/pdf");
}

#[test]
fn thinking_block_builds_correct_json() {
    let block = thinking_block("deep thought", "sig123");
    assert_eq!(block["type"], "thinking");
    assert_eq!(block["thinking"], "deep thought");
    assert_eq!(block["signature"], "sig123");
}

#[test]
fn tool_use_block_builds_correct_json() {
    let mut input = Map::new();
    let _ = input.insert("cmd".into(), serde_json::json!("ls"));
    let block = tool_use_block("toolu_01abc", "execute", &input);
    assert_eq!(block["type"], "tool_use");
    assert_eq!(block["id"], "toolu_01abc");
    assert_eq!(block["name"], "execute");
    assert_eq!(block["input"]["cmd"], "ls");
}

#[test]
fn tool_result_block_success() {
    let content = vec![text_block("output")];
    let block = tool_result_block("toolu_01abc", &content, false);
    assert_eq!(block["type"], "tool_result");
    assert_eq!(block["tool_use_id"], "toolu_01abc");
    assert!(block.get("is_error").is_none());
}

#[test]
fn tool_result_block_error() {
    let content = vec![text_block("error msg")];
    let block = tool_result_block("toolu_01abc", &content, true);
    assert_eq!(block["is_error"], true);
}

// -- AnthropicTool --

#[test]
fn anthropic_tool_serde() {
    let tool = AnthropicTool {
        name: "execute".into(),
        description: "Run commands".into(),
        input_schema: serde_json::json!({"type": "object"}),
        cache_control: None,
    };
    let json = serde_json::to_value(&tool).unwrap();
    assert_eq!(json["name"], "execute");
    assert!(json.get("cache_control").is_none());
}

#[test]
fn anthropic_tool_with_cache_control() {
    let tool = AnthropicTool {
        name: "execute".into(),
        description: "Run commands".into(),
        input_schema: serde_json::json!({"type": "object"}),
        cache_control: Some(CacheControl {
            cache_type: "ephemeral".into(),
            ttl: Some("1h".into()),
        }),
    };
    let json = serde_json::to_value(&tool).unwrap();
    assert_eq!(json["cache_control"]["ttl"], "1h");
}

// -- Constants --

#[test]
fn oauth_system_prompt_prefix_value() {
    assert!(OAUTH_SYSTEM_PROMPT_PREFIX.contains("Claude Code"));
}

#[test]
fn default_model_exists_in_registry() {
    assert!(get_claude_model(DEFAULT_MODEL).is_some());
}

// ── to_api_json ───────────────────────────────────────────────────

#[test]
fn to_api_json_opus_46() {
    let m = get_claude_model("claude-opus-4-6").unwrap();
    let j = m.to_api_json("claude-opus-4-6");
    assert_eq!(j["id"], "claude-opus-4-6");
    assert_eq!(j["name"], "Opus 4.6");
    assert_eq!(j["provider"], "anthropic");
    assert_eq!(j["contextWindow"], 1_000_000);
    assert_eq!(j["tier"], "opus");
    assert_eq!(j["family"], "Claude 4.6");
    assert_eq!(j["supportsThinking"], true);
    assert_eq!(j["supportsReasoning"], true);
    assert!(j["reasoningLevels"].is_array());
    assert_eq!(j["defaultReasoningLevel"], "high");
    assert_eq!(j["recommended"], false);
    assert_eq!(j["isLegacy"], false);
    assert!(j["releaseDate"].is_string());
    assert!(j["sortOrder"].is_number());
}

#[test]
fn to_api_json_no_reasoning() {
    let m = get_claude_model("claude-opus-4-5-20251101").unwrap();
    let j = m.to_api_json("claude-opus-4-5-20251101");
    assert_eq!(j["supportsReasoning"], false);
    assert!(j.get("reasoningLevels").is_none());
    assert!(j.get("defaultReasoningLevel").is_none());
}

#[test]
fn to_api_json_retired() {
    let m = get_claude_model("claude-3-7-sonnet-20250219").unwrap();
    let j = m.to_api_json("claude-3-7-sonnet-20250219");
    assert_eq!(j["isDeprecated"], true);
    assert_eq!(j["deprecationDate"], "2025-10-01");
    assert_eq!(j["isLegacy"], true);
}

#[test]
fn to_api_json_not_retired_no_field() {
    let m = get_claude_model("claude-opus-4-6").unwrap();
    let j = m.to_api_json("claude-opus-4-6");
    assert!(j.get("isDeprecated").is_none());
    assert!(j.get("deprecationDate").is_none());
}

#[test]
fn all_claude_models_api_json_sorted() {
    let models = all_claude_models_api_json();
    assert_eq!(models.len(), 11);
    assert_eq!(models[0]["id"], "claude-opus-4-7");
    assert_eq!(models[0]["sortOrder"], 0);
    assert_eq!(models[1]["id"], "claude-opus-4-6");
    assert_eq!(models[10]["id"], "claude-3-haiku-20240307");
    assert_eq!(models[10]["sortOrder"], 10);
}

#[test]
fn to_api_json_haiku_recommended() {
    let m = get_claude_model("claude-haiku-4-5-20251001").unwrap();
    let j = m.to_api_json("claude-haiku-4-5-20251001");
    assert_eq!(j["recommended"], true);
}

// ── Opus 4.7 ──────────────────────────────────────────────────────

#[test]
fn get_claude_model_opus_4_7_capabilities() {
    let info = get_claude_model("claude-opus-4-7").unwrap();
    assert_eq!(info.short_name, "Opus 4.7");
    assert_eq!(info.family, "Claude 4.7");
    assert!(info.supports_adaptive_thinking);
    assert!(!info.supports_thinking_beta_headers);
    assert!(info.supports_effort);
    assert_eq!(info.default_reasoning_level, Some("xhigh"));
    assert_eq!(info.thinking_display, Some("summarized"));
    assert_eq!(info.input_cost_per_million, 5.0);
    assert_eq!(info.output_cost_per_million, 25.0);
    assert!(info.recommended);
    assert!(!info.retired_generation);
    assert_eq!(info.sort_order, 0);
}

#[test]
fn opus_4_7_supports_xhigh_reasoning() {
    let info = get_claude_model("claude-opus-4-7").unwrap();
    let levels = info.reasoning_levels.unwrap();
    assert!(levels.contains(&"xhigh"));
    assert!(levels.contains(&"max"));
    assert_eq!(levels.len(), 5);
}

#[test]
fn opus_4_6_has_no_thinking_display() {
    // Regression guard: 4.6 must keep the current behavior (no display field).
    let info = get_claude_model("claude-opus-4-6").unwrap();
    assert_eq!(info.thinking_display, None);
}

#[test]
fn to_api_json_opus_4_7_exposes_xhigh() {
    let m = get_claude_model("claude-opus-4-7").unwrap();
    let j = m.to_api_json("claude-opus-4-7");
    assert_eq!(j["id"], "claude-opus-4-7");
    assert_eq!(j["recommended"], true);
    assert_eq!(j["defaultReasoningLevel"], "xhigh");
    let levels = j["reasoningLevels"].as_array().unwrap();
    assert!(levels.iter().any(|v| v == "xhigh"));
}
