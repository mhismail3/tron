use super::*;
use serde_json::json;
use std::sync::Arc;

// -- CapabilityInvocationDraft --

#[test]
fn capability_invocation_default() {
    let tc = CapabilityInvocationDraft::default();
    assert!(tc.id.is_empty());
}

#[test]
fn capability_invocation_serializes_type_field() {
    let tc = CapabilityInvocationDraft {
        id: "tc_1".into(),
        name: "test".into(),
        ..CapabilityInvocationDraft::default()
    };
    let json = serde_json::to_value(&tc).unwrap();
    assert_eq!(json["type"], "capability_invocation");
}

#[test]
fn capability_invocation_deserializes_type_field() {
    let json = r#"{"type":"capability_invocation","id":"tc_1","name":"test","arguments":{}}"#;
    let tc: CapabilityInvocationDraft = serde_json::from_str(json).unwrap();
    assert_eq!(tc.id, "tc_1");
}

#[test]
fn capability_invocation_serde_roundtrip() {
    let mut args = Map::new();
    let _ = args.insert("cmd".into(), json!("ls"));
    let tc = CapabilityInvocationDraft {
        id: "call-1".into(),
        name: "execute".into(),
        arguments: args,
        ..CapabilityInvocationDraft::default()
    };
    let json = serde_json::to_value(&tc).unwrap();
    let back: CapabilityInvocationDraft = serde_json::from_value(json).unwrap();
    assert_eq!(tc, back);
}

// -- normalize helpers --

#[test]
fn normalize_capability_arguments_requires_arguments() {
    let v = json!({"input": {"a": 1}});
    let args = normalize_capability_arguments(&v);
    assert!(args.is_empty());
}

#[test]
fn normalize_capability_arguments_from_arguments() {
    let v = json!({"arguments": {"b": 2}});
    let args = normalize_capability_arguments(&v);
    assert_eq!(args["b"], 2);
}

#[test]
fn normalize_capability_arguments_empty() {
    let v = json!({});
    let args = normalize_capability_arguments(&v);
    assert!(args.is_empty());
}

#[test]
fn normalize_capability_result_id_api_format() {
    let v = json!({"capability_invocation_id": "tc-1"});
    assert_eq!(normalize_capability_result_id(&v), "tc-1");
}

#[test]
fn normalize_capability_result_id_internal_format() {
    let v = json!({"invocationId": "tc-2"});
    assert_eq!(normalize_capability_result_id(&v), "tc-2");
}

#[test]
fn normalize_capability_result_id_missing() {
    let v = json!({});
    assert_eq!(normalize_capability_result_id(&v), "");
}

#[test]
fn normalize_is_error_api_format() {
    let v = json!({"is_error": true});
    assert!(normalize_is_error(&v));
}

#[test]
fn normalize_is_error_internal_format() {
    let v = json!({"isError": true});
    assert!(normalize_is_error(&v));
}

#[test]
fn normalize_is_error_default_false() {
    let v = json!({});
    assert!(!normalize_is_error(&v));
}

// -- TokenUsage --

#[test]
fn token_usage_default() {
    let usage = TokenUsage::default();
    assert_eq!(usage.input_tokens, 0);
    assert_eq!(usage.output_tokens, 0);
    assert!(usage.cache_read_tokens.is_none());
}

#[test]
fn token_usage_serde() {
    let usage = TokenUsage {
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: Some(30),
        cached_input_tokens: Some(30),
        cache_creation_tokens: None,
        cache_creation_5m_tokens: None,
        cache_creation_1h_tokens: None,
        reasoning_output_tokens: Some(5),
        thought_tokens: None,
        tool_use_prompt_tokens: None,
        total_tokens: Some(185),
        provider_type: Some(Provider::Anthropic),
    };
    let json = serde_json::to_value(&usage).unwrap();
    assert_eq!(json["inputTokens"], 100);
    assert_eq!(json["cacheReadTokens"], 30);
    assert_eq!(json["cachedInputTokens"], 30);
    assert_eq!(json["reasoningOutputTokens"], 5);
    assert_eq!(json["totalTokens"], 185);
    assert!(json.get("cacheCreationTokens").is_none());
}

#[test]
fn provider_minimax_serde_roundtrip() {
    let pt = Provider::MiniMax;
    let json = serde_json::to_string(&pt).unwrap();
    assert_eq!(json, "\"minimax\"");
    let back: Provider = serde_json::from_str(&json).unwrap();
    assert_eq!(back, Provider::MiniMax);
}

#[test]
fn provider_kimi_serde_roundtrip() {
    let pt = Provider::Kimi;
    let json = serde_json::to_string(&pt).unwrap();
    assert_eq!(json, "\"kimi\"");
    let back: Provider = serde_json::from_str(&json).unwrap();
    assert_eq!(back, Provider::Kimi);
}

#[test]
fn token_usage_with_minimax_provider() {
    let usage = TokenUsage {
        input_tokens: 200,
        output_tokens: 100,
        provider_type: Some(Provider::MiniMax),
        ..Default::default()
    };
    let json = serde_json::to_value(&usage).unwrap();
    assert_eq!(json["providerType"], "minimax");
}

// -- StopReason --

#[test]
fn stop_reason_serde() {
    assert_eq!(
        serde_json::to_string(&StopReason::EndTurn).unwrap(),
        "\"end_turn\""
    );
    assert_eq!(
        serde_json::to_string(&StopReason::CapabilityInvocation).unwrap(),
        "\"capability_invocation\""
    );
    assert_eq!(
        serde_json::to_string(&StopReason::ModelContextWindowExceeded).unwrap(),
        "\"model_context_window_exceeded\""
    );
}

// -- Message enum --

#[test]
fn message_user_text() {
    let msg = Message::user("hello");
    assert!(msg.is_user());
    assert!(!msg.is_assistant());
    assert!(!msg.is_capability_result());

    let json = serde_json::to_value(&msg).unwrap();
    assert_eq!(json["role"], "user");
    assert_eq!(json["content"], "hello");
}

#[test]
fn message_assistant_text() {
    let msg = Message::assistant("world");
    assert!(msg.is_assistant());
    let json = serde_json::to_value(&msg).unwrap();
    assert_eq!(json["role"], "assistant");
}

#[test]
fn message_assistant_with_stop_reason() {
    let msg = Message::Assistant {
        content: vec![AssistantContent::text("done")],
        usage: None,
        cost: None,
        stop_reason: Some(StopReason::EndTurn),
        thinking: None,
    };
    let json = serde_json::to_value(&msg).unwrap();
    assert_eq!(json["stopReason"], "end_turn");
}

#[test]
fn message_capability_result() {
    let msg = Message::CapabilityResult {
        invocation_id: "tc-1".into(),
        content: CapabilityResultMessageContent::Text("done".into()),
        is_error: None,
    };
    assert!(msg.is_capability_result());
    let json = serde_json::to_value(&msg).unwrap();
    assert_eq!(json["role"], "capabilityResult");
    assert_eq!(json["invocationId"], "tc-1");
}

#[test]
fn message_serde_roundtrip() {
    let msg = Message::user("test");
    let json = serde_json::to_string(&msg).unwrap();
    let back: Message = serde_json::from_str(&json).unwrap();
    assert_eq!(msg, back);
}

// -- extract helpers --

#[test]
fn extract_capability_invocations_from_content() {
    let content = vec![
        AssistantContent::text("text"),
        AssistantContent::CapabilityInvocation {
            id: "tc-1".into(),
            name: "execute".into(),
            arguments: Map::new(),
            thought_signature: None,
        },
        AssistantContent::Thinking {
            thinking: "hmm".into(),
            signature: None,
        },
        AssistantContent::CapabilityInvocation {
            id: "tc-2".into(),
            name: "inspect".into(),
            arguments: Map::new(),
            thought_signature: None,
        },
    ];
    let tcs = extract_capability_invocations(&content);
    assert_eq!(tcs.len(), 2);
}

#[test]
fn extract_assistant_text_from_content() {
    let content = vec![
        AssistantContent::text("first"),
        AssistantContent::CapabilityInvocation {
            id: "tc-1".into(),
            name: "execute".into(),
            arguments: Map::new(),
            thought_signature: None,
        },
        AssistantContent::text("second"),
    ];
    assert_eq!(extract_assistant_text(&content), "first\nsecond");
}

// -- Type guard functions --

#[test]
fn is_provider_capability_result_block_positive() {
    let v =
        json!({"type": "capability_result", "capability_invocation_id": "tc-1", "content": "ok"});
    assert!(is_provider_capability_result_block(&v));
}

#[test]
fn is_provider_capability_result_block_negative() {
    let v = json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
    assert!(!is_provider_capability_result_block(&v));
}

#[test]
fn is_internal_capability_result_block_positive() {
    let v = json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
    assert!(is_internal_capability_result_block(&v));
}

#[test]
fn is_any_capability_result_block_both_formats() {
    let api =
        json!({"type": "capability_result", "capability_invocation_id": "tc-1", "content": "ok"});
    let internal = json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
    assert!(is_any_capability_result_block(&api));
    assert!(is_any_capability_result_block(&internal));
}

#[test]
fn is_provider_capability_invocation_block_positive() {
    let v =
        json!({"type": "capability_invocation", "id": "tc-1", "name": "execute", "arguments": {}});
    assert!(is_provider_capability_invocation_block(&v));
}

#[test]
fn is_provider_capability_invocation_block_negative_missing_arguments() {
    let v = json!({"type": "capability_invocation", "id": "tc-1", "name": "execute"});
    assert!(!is_provider_capability_invocation_block(&v));
}

// -- Context --

#[test]
fn context_default_is_empty() {
    let ctx = Context::default();
    assert!(ctx.system_prompt.is_none());
    assert!(ctx.messages.is_empty());
    assert!(ctx.capabilities.is_none());
}

#[test]
fn context_serde_roundtrip() {
    let ctx = Context {
        system_prompt: Some("You are a helpful assistant.".into()),
        messages: vec![Message::user("hi")].into(),
        capabilities: None,
        working_directory: Some("/tmp".into()),
        rules_content: None,
        memory_content: None,
        skill_index_context: None,
        skill_activation_context: None,
        skill_context: None,
        skill_removal_context: None,
        job_results_context: None,
        dynamic_rules_context: None,
        capability_primer_context: None,
        hook_context: None,
        server_origin: None,
    };
    let json = serde_json::to_string(&ctx).unwrap();
    let back: Context = serde_json::from_str(&json).unwrap();
    assert_eq!(ctx, back);
}

#[test]
fn context_messages_deref_to_slice() {
    let ctx = Context {
        messages: vec![Message::user("hello")].into(),
        ..Default::default()
    };
    let slice: &[Message] = &ctx.messages;
    assert_eq!(slice.len(), 1);
}

#[test]
fn context_clone_shares_arc() {
    let ctx = Context {
        messages: vec![Message::user("hello")].into(),
        ..Default::default()
    };
    let ctx2 = ctx.clone();
    assert!(Arc::ptr_eq(&ctx.messages, &ctx2.messages));
}

// -- Provider --

#[test]
fn provider_serde_roundtrip() {
    assert_eq!(
        serde_json::to_string(&Provider::Anthropic).unwrap(),
        "\"anthropic\""
    );
    assert_eq!(
        serde_json::to_string(&Provider::OpenAi).unwrap(),
        "\"openai\""
    );
    assert_eq!(
        serde_json::to_string(&Provider::OpenAiCodex).unwrap(),
        "\"openai-codex\""
    );
    assert_eq!(
        serde_json::to_string(&Provider::Google).unwrap(),
        "\"google\""
    );
    assert_eq!(
        serde_json::to_string(&Provider::MiniMax).unwrap(),
        "\"minimax\""
    );
    assert_eq!(serde_json::to_string(&Provider::Kimi).unwrap(), "\"kimi\"");
    assert_eq!(
        serde_json::to_string(&Provider::Ollama).unwrap(),
        "\"ollama\""
    );
    assert_eq!(
        serde_json::to_string(&Provider::Unknown).unwrap(),
        "\"unknown\""
    );

    let back: Provider = serde_json::from_str("\"anthropic\"").unwrap();
    assert_eq!(back, Provider::Anthropic);

    // Unknown catches unrecognized strings via #[serde(other)]
    let unknown: Provider = serde_json::from_str("\"some-future-provider\"").unwrap();
    assert_eq!(unknown, Provider::Unknown);
}

#[test]
fn provider_display() {
    assert_eq!(Provider::Anthropic.to_string(), "anthropic");
    assert_eq!(Provider::OpenAi.to_string(), "openai");
    assert_eq!(Provider::OpenAiCodex.to_string(), "openai-codex");
    assert_eq!(Provider::MiniMax.to_string(), "minimax");
    assert_eq!(Provider::Kimi.to_string(), "kimi");
    assert_eq!(Provider::Ollama.to_string(), "ollama");
    assert_eq!(Provider::Unknown.to_string(), "unknown");
}

#[test]
fn provider_from_str() {
    assert_eq!(
        "anthropic".parse::<Provider>().unwrap(),
        Provider::Anthropic
    );
    assert_eq!("openai".parse::<Provider>().unwrap(), Provider::OpenAi);
    assert_eq!(
        "openai-codex".parse::<Provider>().unwrap(),
        Provider::OpenAiCodex
    );
    assert_eq!("google".parse::<Provider>().unwrap(), Provider::Google);
    assert_eq!("minimax".parse::<Provider>().unwrap(), Provider::MiniMax);
    assert_eq!("kimi".parse::<Provider>().unwrap(), Provider::Kimi);
    assert_eq!("ollama".parse::<Provider>().unwrap(), Provider::Ollama);
    assert!("nonexistent".parse::<Provider>().is_err());
}

#[test]
fn provider_as_str() {
    assert_eq!(Provider::Anthropic.as_str(), "anthropic");
    assert_eq!(Provider::OpenAi.as_str(), "openai");
    assert_eq!(Provider::OpenAiCodex.as_str(), "openai-codex");
    assert_eq!(Provider::Google.as_str(), "google");
}

// -- is_compaction_summary --

#[test]
fn is_compaction_summary_true() {
    let msg = Message::user("[Context from earlier in this conversation]\n\nSummary here.");
    assert!(msg.is_compaction_summary());
}

#[test]
fn is_compaction_summary_false_regular_user() {
    let msg = Message::user("Hello, can you help me?");
    assert!(!msg.is_compaction_summary());
}

#[test]
fn is_compaction_summary_false_assistant() {
    let msg = Message::assistant("[Context from earlier in this conversation]");
    assert!(!msg.is_compaction_summary());
}

#[test]
fn is_compaction_summary_false_capability_result() {
    let msg = Message::CapabilityResult {
        invocation_id: "tc-1".into(),
        content: CapabilityResultMessageContent::Text(
            "[Context from earlier in this conversation]".into(),
        ),
        is_error: None,
    };
    assert!(!msg.is_compaction_summary());
}

#[test]
fn is_compaction_summary_false_similar_prefix() {
    let msg = Message::user("[Context from another source]");
    assert!(!msg.is_compaction_summary());
}

// -- is_real_user_turn --

#[test]
fn is_real_user_turn_regular() {
    let msg = Message::user("Help me with this code.");
    assert!(msg.is_real_user_turn());
}

#[test]
fn is_real_user_turn_compaction_summary() {
    let msg = Message::user("[Context from earlier in this conversation]\n\nSummary.");
    assert!(!msg.is_real_user_turn());
}

#[test]
fn is_real_user_turn_assistant() {
    let msg = Message::assistant("Sure, I can help.");
    assert!(!msg.is_real_user_turn());
}
