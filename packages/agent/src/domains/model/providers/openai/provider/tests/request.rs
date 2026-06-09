use super::*;

// ── Request shaping ─────────────────────────────────────────────

#[test]
fn build_request_gpt55_codex_clamps_none_and_max_output() {
    let mut config = oauth_config("gpt-5.5");
    config.max_tokens = Some(200_000);
    let provider = OpenAIProvider::new(config);
    let request = provider.build_request(
        &Context::default(),
        &ProviderStreamOptions {
            reasoning_effort: Some(ReasoningEffort::None),
            ..Default::default()
        },
    );

    assert_eq!(request.model, "gpt-5.5");
    assert_eq!(request.max_output_tokens, Some(128_000));
    assert_eq!(request.reasoning.unwrap().effort, "low");
    assert_eq!(request.text.unwrap().verbosity, "low");
}

#[test]
fn build_request_gpt55_platform_preserves_none_and_platform_verbosity() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5.5"));
    let request = provider.build_request(
        &Context::default(),
        &ProviderStreamOptions {
            max_tokens: Some(200_000),
            reasoning_effort: Some(ReasoningEffort::None),
            ..Default::default()
        },
    );

    assert_eq!(request.max_output_tokens, Some(128_000));
    assert_eq!(request.reasoning.unwrap().effort, "none");
    assert_eq!(request.text.unwrap().verbosity, "medium");
}

#[test]
fn build_request_configured_openai_model_preserves_exact_id() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5.2-codex"));
    let request = provider.build_request(&Context::default(), &ProviderStreamOptions::default());
    assert_eq!(request.model, "gpt-5.2-codex");
}

#[test]
fn build_request_snapshot_preserves_exact_model_id() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5.5-2026-04-23"));
    let request = provider.build_request(&Context::default(), &ProviderStreamOptions::default());
    assert_eq!(request.model, "gpt-5.5-2026-04-23");
}

#[test]
fn build_request_gpt5_platform_sends_minimal_reasoning() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5"));
    let request = provider.build_request(
        &Context::default(),
        &ProviderStreamOptions {
            reasoning_effort: Some(ReasoningEffort::Minimal),
            ..Default::default()
        },
    );
    assert_eq!(request.reasoning.unwrap().effort, "minimal");
}

#[test]
fn build_request_text_only_model_omits_reasoning_and_tools() {
    let provider = OpenAIProvider::new(api_key_config("gpt-4"));
    let context = Context {
        capabilities: Some(vec![test_tool()]),
        ..Default::default()
    };
    let request = provider.build_request(&context, &ProviderStreamOptions::default());
    assert_eq!(request.model, "gpt-4");
    assert!(request.reasoning.is_none());
    assert!(request.capabilities.is_none());
}

#[test]
fn build_request_serializes_capabilities_as_provider_tools() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5"));
    let context = Context {
        capabilities: Some(vec![test_tool()]),
        ..Default::default()
    };
    let request = provider.build_request(&context, &ProviderStreamOptions::default());
    let body = serde_json::to_value(&request).expect("request serializes");

    assert!(body.get("tools").is_some());
    assert!(body.get("capabilities").is_none());
    assert_eq!(body["tools"][0]["name"], "echo");
}

#[test]
fn build_request_compiles_primitive_context_into_instructions() {
    let provider = OpenAIProvider::new(oauth_config("gpt-5.5"));
    let context = Context {
        system_prompt: Some("Agent soul".into()),
        messages: std::sync::Arc::from([Message::user("Hello")]),
        capabilities: Some(vec![test_tool()]),
        working_directory: Some("/workspace".into()),
        agent_state_context: Some("Remember the teardown scorecard.".into()),
        server_origin: Some("localhost:9847".into()),
    };

    let request = provider.build_request(&context, &ProviderStreamOptions::default());
    let instructions = request.instructions.expect("instructions are required");

    assert!(instructions.contains("Agent soul"));
    assert!(instructions.contains("Remember the teardown scorecard."));
    assert!(instructions.contains("Server: localhost:9847"));
    assert!(instructions.contains("Current working directory: /workspace"));
    assert!(instructions.contains("Use ONLY this model-facing tool"));
    assert!(instructions.contains("execute"));

    assert_eq!(request.input.len(), 1);
    match &request.input[0] {
        ResponsesInputItem::Message { role, content, .. } => {
            assert_eq!(role, "user");
            assert_eq!(content.len(), 1);
            assert!(matches!(
                &content[0],
                MessageContent::InputText { text } if text == "Hello"
            ));
        }
        other => panic!("expected user message input, got {other:?}"),
    }
}

#[test]
fn build_request_merges_provider_instructions_with_context() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5"));
    let context = Context {
        system_prompt: Some("Agent soul".into()),
        working_directory: Some("/workspace".into()),
        ..Default::default()
    };
    let request = provider.build_request(
        &context,
        &ProviderStreamOptions {
            provider_instructions: Some("Provider front matter".into()),
            ..Default::default()
        },
    );
    let instructions = request.instructions.expect("instructions are required");

    let provider_index = instructions
        .find("Provider front matter")
        .expect("provider instructions included");
    let soul_index = instructions
        .find("Agent soul")
        .expect("context instructions included");
    assert!(provider_index < soul_index);
    assert!(instructions.contains("Current working directory: /workspace"));
}

#[tokio::test]
async fn stream_rejects_non_streaming_platform_model_before_request() {
    let provider = OpenAIProvider::new(api_key_config("gpt-5.5-pro"));
    let err = match provider
        .stream_internal(&Context::default(), &ProviderStreamOptions::default())
        .await
    {
        Ok(_) => panic!("expected non-streaming model rejection"),
        Err(err) => err,
    };
    assert!(
        err.to_string().contains("streaming Responses provider"),
        "{err}"
    );
}
