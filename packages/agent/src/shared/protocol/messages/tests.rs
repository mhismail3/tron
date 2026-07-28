use super::*;
use serde_json::json;
use std::sync::Arc;

// -- ToolInvocationDraft --

#[test]
fn tool_invocation_default() {
    let tc = ToolInvocationDraft::default();
    assert!(tc.id.is_empty());
}

#[test]
fn tool_invocation_serializes_type_field() {
    let tc = ToolInvocationDraft {
        id: "tc_1".into(),
        name: "test".into(),
        ..ToolInvocationDraft::default()
    };
    let json = serde_json::to_value(&tc).unwrap();
    assert_eq!(json["type"], "tool_invocation");
}

#[test]
fn tool_invocation_deserializes_type_field() {
    let json = r#"{"type":"tool_invocation","id":"tc_1","name":"test","arguments":{}}"#;
    let tc: ToolInvocationDraft = serde_json::from_str(json).unwrap();
    assert_eq!(tc.id, "tc_1");
}

#[test]
fn tool_invocation_serde_roundtrip() {
    let mut args = Map::new();
    let _ = args.insert("cmd".into(), json!("ls"));
    let tc = ToolInvocationDraft {
        id: "call-1".into(),
        name: "test_tool".into(),
        arguments: args,
        ..ToolInvocationDraft::default()
    };
    let json = serde_json::to_value(&tc).unwrap();
    let back: ToolInvocationDraft = serde_json::from_value(json).unwrap();
    assert_eq!(tc, back);
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
        serde_json::to_string(&StopReason::ToolInvocation).unwrap(),
        "\"tool_invocation\""
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
    assert!(!msg.is_tool_result());

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
fn message_tool_result() {
    let msg = Message::ToolResult {
        invocation_id: "tc-1".into(),
        content: ToolResultMessageContent::Text("done".into()),
        is_error: None,
    };
    assert!(msg.is_tool_result());
    let json = serde_json::to_value(&msg).unwrap();
    assert_eq!(json["role"], "toolResult");
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
fn extract_assistant_text_from_content() {
    let content = vec![
        AssistantContent::text("first"),
        AssistantContent::ToolInvocation {
            id: "tc-1".into(),
            name: "test_tool".into(),
            arguments: Map::new(),
            thought_signature: None,
        },
        AssistantContent::text("second"),
    ];
    assert_eq!(extract_assistant_text(&content), "first\nsecond");
}

// -- Context --

#[test]
fn context_default_is_empty() {
    let ctx = Context::default();
    assert!(ctx.system_prompt.is_none());
    assert!(ctx.messages.is_empty());
    assert!(ctx.tools.is_none());
}

#[test]
fn context_serde_roundtrip() {
    let ctx = Context {
        system_prompt: Some("You are a helpful assistant.".into()),
        messages: vec![Message::user("hi")].into(),
        tools: None,
        request_context: Vec::new(),
        cache_layout: Default::default(),
        working_directory: Some("/tmp".into()),
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
fn is_compaction_summary_false_tool_result() {
    let msg = Message::ToolResult {
        invocation_id: "tc-1".into(),
        content: ToolResultMessageContent::Text(
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
