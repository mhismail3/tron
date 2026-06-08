use super::*;
use crate::domains::model::providers::anthropic::types::AnthropicProviderSettings;
use crate::domains::model::providers::provider::AnthropicEffortLevel;

fn test_config(auth: AnthropicAuth) -> AnthropicConfig {
    AnthropicConfig {
        model: "claude-opus-4-6".into(),
        auth,
        max_tokens: None,
        base_url: None,
        retry: None,
        provider_settings: AnthropicProviderSettings::default(),
    }
}

fn api_key_config() -> AnthropicConfig {
    test_config(AnthropicAuth::ApiKey {
        api_key: "sk-test-key".into(),
    })
}

fn oauth_config() -> AnthropicConfig {
    test_config(AnthropicAuth::OAuth {
        tokens: crate::domains::auth::credentials::OAuthTokens {
            access_token: "at-test".into(),
            refresh_token: "rt-test".into(),
            expires_at: 9_999_999_999_999,
        },
    })
}

fn context_with_system(prompt: &str) -> Context {
    Context {
        system_prompt: Some(prompt.into()),
        ..Context::default()
    }
}

// ── Provider metadata ───────────────────────────────────────────────

#[test]
fn provider_type_is_anthropic() {
    let provider = AnthropicProvider::new(api_key_config());
    assert_eq!(
        provider.provider_type(),
        crate::shared::protocol::messages::Provider::Anthropic
    );
}

#[test]
fn provider_model_returns_config_model() {
    let provider = AnthropicProvider::new(api_key_config());
    assert_eq!(provider.model(), "claude-opus-4-6");
}

// ── is_oauth ────────────────────────────────────────────────────────

#[test]
fn is_oauth_true_for_oauth_auth() {
    let provider = AnthropicProvider::new(oauth_config());
    assert!(provider.is_oauth());
}

#[test]
fn is_oauth_false_for_api_key() {
    let provider = AnthropicProvider::new(api_key_config());
    assert!(!provider.is_oauth());
}

// ── Headers ─────────────────────────────────────────────────────────

#[test]
fn headers_api_key() {
    let provider = AnthropicProvider::new(api_key_config());
    let headers = provider.build_headers().unwrap();
    assert!(headers.get("x-api-key").is_some());
    assert_eq!(headers["x-api-key"], "sk-test-key");
    assert_eq!(headers["anthropic-version"], API_VERSION);
}

#[test]
fn headers_api_key_no_oauth_beta() {
    // Opus 4.6 with API key: no beta headers at all
    let provider = AnthropicProvider::new(api_key_config());
    let headers = provider.build_headers().unwrap();
    assert!(headers.get("anthropic-beta").is_none());
    assert!(
        headers
            .get("anthropic-dangerous-direct-browser-access")
            .is_none()
    );
}

#[test]
fn headers_api_key_thinking_model() {
    // Haiku 4.5 with API key: thinking beta only, no OAuth beta
    let mut cfg = api_key_config();
    cfg.model = "claude-haiku-4-5-20251001".into();
    let provider = AnthropicProvider::new(cfg);
    let headers = provider.build_headers().unwrap();
    assert_eq!(headers["anthropic-beta"], "interleaved-thinking-2025-05-14");
    assert!(
        headers
            .get("anthropic-dangerous-direct-browser-access")
            .is_none()
    );
}

#[test]
fn headers_oauth() {
    let provider = AnthropicProvider::new(oauth_config());
    let headers = provider.build_headers().unwrap();
    assert_eq!(headers[AUTHORIZATION], "Bearer at-test");
    assert!(headers.get("x-api-key").is_none());
}

#[test]
fn headers_oauth_has_browser_access() {
    let provider = AnthropicProvider::new(oauth_config());
    let headers = provider.build_headers().unwrap();
    assert_eq!(headers["anthropic-dangerous-direct-browser-access"], "true");
}

#[test]
fn headers_oauth_opus_46_has_oauth_beta_only() {
    // Opus 4.6 doesn't need thinking beta → only `oauth-2025-04-20`
    let provider = AnthropicProvider::new(oauth_config());
    let headers = provider.build_headers().unwrap();
    assert_eq!(headers["anthropic-beta"], "oauth-2025-04-20");
}

#[test]
fn headers_oauth_haiku_45_has_full_beta() {
    // Haiku 4.5 needs thinking beta → full beta string with oauth prefix
    let mut cfg = oauth_config();
    cfg.model = "claude-haiku-4-5-20251001".into();
    let provider = AnthropicProvider::new(cfg);
    let headers = provider.build_headers().unwrap();
    let beta = headers["anthropic-beta"].to_str().unwrap();
    assert!(beta.contains("oauth-2025-04-20"), "must contain oauth beta");
    assert!(
        beta.contains("interleaved-thinking-2025-05-14"),
        "must contain thinking beta"
    );
}

#[test]
fn headers_oauth_sonnet_45_has_full_beta() {
    let mut cfg = oauth_config();
    cfg.model = "claude-sonnet-4-5-20250929".into();
    let provider = AnthropicProvider::new(cfg);
    let headers = provider.build_headers().unwrap();
    let beta = headers["anthropic-beta"].to_str().unwrap();
    assert!(beta.starts_with("oauth-2025-04-20"));
}

#[test]
fn headers_oauth_unknown_model_gets_full_beta() {
    // Unknown model → treat as needing thinking beta (safe default)
    let mut cfg = oauth_config();
    cfg.model = "claude-future-model".into();
    let provider = AnthropicProvider::new(cfg);
    let headers = provider.build_headers().unwrap();
    let beta = headers["anthropic-beta"].to_str().unwrap();
    assert!(beta.contains("oauth-2025-04-20"));
    assert!(beta.contains("interleaved-thinking"));
}

#[test]
fn headers_oauth_custom_beta_from_settings() {
    let mut cfg = oauth_config();
    cfg.model = "claude-haiku-4-5-20251001".into();
    cfg.provider_settings.oauth_beta_headers = "oauth-2025-04-20,custom-beta-2025-06-01".into();
    let provider = AnthropicProvider::new(cfg);
    let headers = provider.build_headers().unwrap();
    assert_eq!(
        headers["anthropic-beta"],
        "oauth-2025-04-20,custom-beta-2025-06-01"
    );
}

// ── System prompt ───────────────────────────────────────────────────

#[test]
fn system_param_api_key_returns_cached_blocks() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = context_with_system("You are helpful.");
    let param = provider.build_system_param(&ctx).unwrap();
    // API key now returns array with cache breakpoints, not a plain string
    assert!(param.is_array(), "should return array, not string");
    let blocks = param.as_array().unwrap();
    // No OAuth prefix block
    assert_ne!(blocks[0]["text"], OAUTH_SYSTEM_PROMPT_PREFIX);
    // Last block has cache_control
    let last = blocks.last().unwrap();
    assert!(last.get("cache_control").is_some());
}

#[test]
fn system_param_empty_context() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = Context::default();
    assert!(provider.build_system_param(&ctx).is_none());
}

#[test]
fn system_param_oauth_has_prefix() {
    let provider = AnthropicProvider::new(oauth_config());
    let ctx = context_with_system("You are helpful.");
    let param = provider.build_system_param(&ctx).unwrap();
    let blocks: Vec<Value> = serde_json::from_value(param).unwrap();
    assert!(blocks.len() >= 2);
    assert!(blocks[0]["text"].as_str().unwrap().contains("Claude Code"));
}

#[test]
fn system_param_oauth_cache_breakpoints_stable_and_volatile() {
    let mut config = oauth_config();
    config.provider_settings.system_prompt_prefix = Some("Prefix".into());
    let provider = AnthropicProvider::new(config);
    let ctx = Context {
        system_prompt: Some("System".into()),
        agent_state_context: Some("State".into()),
        ..Context::default()
    };
    let param = provider.build_system_param(&ctx).unwrap();
    let blocks: Vec<Value> = serde_json::from_value(param).unwrap();

    // Prefix + system (stable) + agent state (volatile)
    assert_eq!(blocks.len(), 3);

    // Breakpoint 2: last stable block (index 1 = system) -> 1h
    assert_eq!(blocks[1]["cache_control"]["ttl"], "1h");

    // Breakpoint 3: last volatile block (index 2 = state) -> ephemeral (no ttl)
    assert_eq!(blocks[2]["cache_control"]["type"], "ephemeral");
    assert!(
        blocks[2]["cache_control"].get("ttl").is_none()
            || blocks[2]["cache_control"]["ttl"].is_null()
    );
}

#[test]
fn system_param_oauth_only_stable() {
    let provider = AnthropicProvider::new(oauth_config());
    let ctx = Context {
        system_prompt: Some("System".into()),
        ..Context::default()
    };
    let param = provider.build_system_param(&ctx).unwrap();
    let blocks: Vec<Value> = serde_json::from_value(param).unwrap();

    // Last block should have 1h TTL (only stable)
    let last = blocks.last().unwrap();
    assert_eq!(last["cache_control"]["ttl"], "1h");
}

// ── Tools ───────────────────────────────────────────────────────────

#[test]
fn build_tools_none() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = Context::default();
    assert!(provider.build_tools(&ctx).is_none());
}

#[test]
fn build_tools_api_key_has_cache() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = Context {
        capabilities: Some(vec![
            crate::shared::protocol::model_capabilities::ModelCapability {
                name: "execute".into(),
                description: "Execute inspected capabilities".into(),
                parameters:
                    crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: serde_json::Map::default(),
                    },
            },
        ]),
        ..Context::default()
    };
    let capabilities = provider.build_tools(&ctx).unwrap();
    assert_eq!(capabilities.len(), 1);
    assert_eq!(capabilities[0].name, "execute");
    // API key now gets cache too
    assert!(capabilities[0].cache_control.is_some());
    assert_eq!(
        capabilities[0]
            .cache_control
            .as_ref()
            .unwrap()
            .ttl
            .as_deref(),
        Some("1h")
    );
}

#[test]
fn request_serializes_capabilities_as_provider_tools() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = Context {
        capabilities: Some(vec![
            crate::shared::protocol::model_capabilities::ModelCapability {
                name: "execute".into(),
                description: "Execute inspected capabilities".into(),
                parameters:
                    crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: serde_json::Map::default(),
                    },
            },
        ]),
        ..Context::default()
    };
    let request = provider.build_request(
        &ctx,
        &ProviderStreamOptions::default(),
        vec![AnthropicMessageParam {
            role: "user".into(),
            content: vec![json!({"type": "text", "text": "hi"})],
        }],
    );
    let body = serde_json::to_value(&request).expect("request serializes");

    assert!(body.get("tools").is_some());
    assert!(body.get("capabilities").is_none());
    assert_eq!(body["tools"][0]["name"], "execute");
}

#[test]
fn build_tools_oauth_last_has_cache() {
    let provider = AnthropicProvider::new(oauth_config());
    let ctx = Context {
        capabilities: Some(vec![
            crate::shared::protocol::model_capabilities::ModelCapability {
                name: "search".into(),
                description: "Search capability catalog".into(),
                parameters:
                    crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: serde_json::Map::default(),
                    },
            },
            crate::shared::protocol::model_capabilities::ModelCapability {
                name: "execute".into(),
                description: "Execute inspected capabilities".into(),
                parameters:
                    crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                        schema_type: "object".into(),
                        properties: None,
                        required: None,
                        description: None,
                        extra: serde_json::Map::default(),
                    },
            },
        ]),
        ..Context::default()
    };
    let capabilities = provider.build_tools(&ctx).unwrap();
    assert!(capabilities[0].cache_control.is_none()); // First tool: no cache
    assert_eq!(
        capabilities[1]
            .cache_control
            .as_ref()
            .unwrap()
            .ttl
            .as_deref(),
        Some("1h")
    );
}

// ── Thinking config ─────────────────────────────────────────────────

#[test]
fn thinking_config_disabled() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions::default();
    assert!(provider.build_thinking_config(&options).is_none());
}

#[test]
fn thinking_config_adaptive_opus_46() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions {
        enable_thinking: Some(true),
        ..Default::default()
    };
    let config = provider.build_thinking_config(&options).unwrap();
    assert_eq!(config["type"], "adaptive");
    // Regression guard: 4.6 must not send the `display` field (API default
    // was "summarized"; explicit display opt-in is a 4.7-only change).
    assert!(config.get("display").is_none());
}

#[test]
fn thinking_config_adaptive_opus_4_7_opts_in_to_summarized() {
    let mut cfg = api_key_config();
    cfg.model = "claude-opus-4-7".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        enable_thinking: Some(true),
        ..Default::default()
    };
    let config = provider.build_thinking_config(&options).unwrap();
    assert_eq!(config["type"], "adaptive");
    assert_eq!(config["display"], "summarized");
}

#[test]
fn thinking_config_budget_older_model() {
    let mut cfg = api_key_config();
    cfg.model = "claude-sonnet-4-5-20250929".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        enable_thinking: Some(true),
        thinking_budget: Some(8000),
        ..Default::default()
    };
    let config = provider.build_thinking_config(&options).unwrap();
    assert_eq!(config["type"], "enabled");
    assert_eq!(config["budget_tokens"], 8000);
}

#[test]
fn thinking_config_budget_default() {
    let mut cfg = api_key_config();
    cfg.model = "claude-sonnet-4-5-20250929".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        enable_thinking: Some(true),
        ..Default::default()
    };
    let config = provider.build_thinking_config(&options).unwrap();
    // Default: max_output / 4 = 64000 / 4 = 16000
    assert_eq!(config["budget_tokens"], 16000);
}

#[test]
fn thinking_config_none_for_unsupported_model() {
    let mut cfg = api_key_config();
    cfg.model = "claude-3-haiku-20240307".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        enable_thinking: Some(true),
        ..Default::default()
    };
    assert!(provider.build_thinking_config(&options).is_none());
}

// ── Output config (effort) ──────────────────────────────────────────

#[test]
fn output_config_opus_46_with_effort() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions {
        effort_level: Some(AnthropicEffortLevel::High),
        ..Default::default()
    };
    let config = provider.build_output_config(&options).unwrap();
    assert_eq!(config["effort"], "high");
}

#[test]
fn output_config_no_effort() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions::default();
    assert!(provider.build_output_config(&options).is_none());
}

#[test]
fn output_config_non_effort_model() {
    let mut cfg = api_key_config();
    cfg.model = "claude-sonnet-4-5-20250929".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        effort_level: Some(AnthropicEffortLevel::High),
        ..Default::default()
    };
    assert!(provider.build_output_config(&options).is_none());
}

#[test]
fn output_config_opus_4_7_xhigh() {
    let mut cfg = api_key_config();
    cfg.model = "claude-opus-4-7".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        effort_level: Some(AnthropicEffortLevel::Xhigh),
        ..Default::default()
    };
    let config = provider.build_output_config(&options).unwrap();
    assert_eq!(config["effort"], "xhigh");
}

#[test]
fn output_config_opus_4_7_max() {
    let mut cfg = api_key_config();
    cfg.model = "claude-opus-4-7".into();
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions {
        effort_level: Some(AnthropicEffortLevel::Max),
        ..Default::default()
    };
    let config = provider.build_output_config(&options).unwrap();
    assert_eq!(config["effort"], "max");
}

// ── Max tokens ──────────────────────────────────────────────────────

#[test]
fn max_tokens_from_options() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions {
        max_tokens: Some(4096),
        ..Default::default()
    };
    assert_eq!(provider.calculate_max_tokens(&options), 4096);
}

#[test]
fn max_tokens_from_config() {
    let mut cfg = api_key_config();
    cfg.max_tokens = Some(8000);
    let provider = AnthropicProvider::new(cfg);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.calculate_max_tokens(&options), 8000);
}

#[test]
fn max_tokens_from_model() {
    let provider = AnthropicProvider::new(api_key_config());
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.calculate_max_tokens(&options), 128_000); // Opus 4.6
}

// ── Request building ────────────────────────────────────────────────

#[test]
fn build_request_basic() {
    let provider = AnthropicProvider::new(api_key_config());
    let ctx = context_with_system("You are helpful.");
    let options = ProviderStreamOptions::default();
    let messages = convert_messages(&ctx.messages);
    let req = provider.build_request(&ctx, &options, messages);

    assert_eq!(req.model, "claude-opus-4-6");
    assert!(req.stream);
    assert!(req.system.is_some());
    assert!(req.thinking.is_none());
    assert!(req.output_config.is_none());
}

// ── API error parsing (via shared crate::domains::model::providers::error_parsing) ────────────

// ── Cache breakpoint on last user message ───────────────────────────

#[test]
fn cache_last_user_message() {
    let mut messages = vec![
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
            content: vec![json!({"type": "text", "text": "question"})],
        },
    ];
    AnthropicProvider::apply_cache_to_last_user_message(&mut messages);

    // Last user message (index 2) should have cache_control
    assert!(messages[2].content[0]["cache_control"].is_object());
    assert_eq!(messages[2].content[0]["cache_control"]["type"], "ephemeral");

    // First user message should NOT have cache_control
    assert!(messages[0].content[0].get("cache_control").is_none());
}
