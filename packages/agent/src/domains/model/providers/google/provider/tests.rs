use super::*;

fn oauth_tokens() -> OAuthTokens {
    OAuthTokens {
        access_token: "ya29.test".into(),
        refresh_token: "rt-test".into(),
        expires_at: crate::domains::auth::provider_credentials::now_ms() + 3_600_000, // 1 hour
    }
}

fn oauth_config() -> GoogleConfig {
    GoogleConfig {
        model: "gemini-3-pro-preview".into(),
        auth: GoogleAuth::Oauth {
            tokens: oauth_tokens(),
            project_id: Some("my-project".into()),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        thinking_level: None,
        thinking_budget: None,
        safety_settings: None,
        provider_settings: GoogleApiSettings::default(),
    }
}

fn api_key_config() -> GoogleConfig {
    GoogleConfig {
        model: "gemini-2.5-flash".into(),
        auth: GoogleAuth::ApiKey {
            api_key: "AIza-test-key".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        thinking_level: None,
        thinking_budget: None,
        safety_settings: None,
        provider_settings: GoogleApiSettings::default(),
    }
}

// ── Provider metadata ─────────────────────────────────────────────

#[test]
fn provider_type_is_google() {
    let provider = GoogleProvider::new(oauth_config());
    assert_eq!(
        provider.provider_type(),
        crate::shared::messages::Provider::Google
    );
}

#[test]
fn provider_model_returns_config_model() {
    let provider = GoogleProvider::new(oauth_config());
    assert_eq!(provider.model(), "gemini-3-pro-preview");
}

// ── API URL construction ──────────────────────────────────────────

#[test]
fn api_url_oauth_uses_standard_gemini_api() {
    let provider = GoogleProvider::new(oauth_config());
    let url = provider.get_api_url("streamGenerateContent");
    assert!(url.contains("generativelanguage.googleapis.com"));
    assert!(url.contains("models/gemini-3-pro-preview:streamGenerateContent"));
    assert!(url.contains("alt=sse"));
    // No API key in URL for OAuth
    assert!(!url.contains("key="));
}

#[test]
fn oauth_uses_standard_endpoint_without_project_id() {
    let mut config = oauth_config();
    config.auth = GoogleAuth::Oauth {
        tokens: oauth_tokens(),
        project_id: None,
    };
    let provider = GoogleProvider::new(config);
    let url = provider.get_api_url("streamGenerateContent");
    assert!(url.contains("generativelanguage.googleapis.com"));
    assert!(url.contains("models/gemini-3-pro-preview:streamGenerateContent"));
}

#[test]
fn api_url_api_key() {
    let provider = GoogleProvider::new(api_key_config());
    let url = provider.get_api_url("streamGenerateContent");
    assert!(url.contains("generativelanguage.googleapis.com"));
    assert!(url.contains("models/gemini-2.5-flash"));
    assert!(url.contains("key=AIza-test-key"));
}

#[test]
fn api_url_api_key_custom_base() {
    let mut config = api_key_config();
    config.base_url = Some("https://custom.api.com/v1".into());
    let provider = GoogleProvider::new(config);
    let url = provider.get_api_url("streamGenerateContent");
    assert!(url.starts_with("https://custom.api.com/v1"));
}

// ── Generation config ─────────────────────────────────────────────

#[test]
fn gen_config_gemini3_forces_temperature_1() {
    let provider = GoogleProvider::new(oauth_config());
    let options = ProviderStreamOptions {
        temperature: Some(0.7),
        ..Default::default()
    };
    let gc = provider.build_generation_config(&options);
    assert_eq!(gc.temperature, Some(1.0));
}

#[test]
fn gen_config_gemini25_preserves_temperature() {
    let provider = GoogleProvider::new(api_key_config());
    let options = ProviderStreamOptions {
        temperature: Some(0.7),
        ..Default::default()
    };
    let gc = provider.build_generation_config(&options);
    assert_eq!(gc.temperature, Some(0.7));
}

#[test]
fn gen_config_max_tokens_from_options() {
    let provider = GoogleProvider::new(oauth_config());
    let options = ProviderStreamOptions {
        max_tokens: Some(8192),
        ..Default::default()
    };
    let gc = provider.build_generation_config(&options);
    assert_eq!(gc.max_output_tokens, Some(8192));
}

#[test]
fn gen_config_max_tokens_from_config() {
    let mut config = oauth_config();
    config.max_tokens = Some(4096);
    let provider = GoogleProvider::new(config);
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    assert_eq!(gc.max_output_tokens, Some(4096));
}

#[test]
fn gen_config_max_tokens_from_model_default() {
    let provider = GoogleProvider::new(oauth_config());
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    assert_eq!(gc.max_output_tokens, Some(65_536)); // gemini-3-pro-preview default
}

// ── Thinking config ───────────────────────────────────────────────

#[test]
fn thinking_config_gemini3_uses_level() {
    let provider = GoogleProvider::new(oauth_config());
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(true, &opts).unwrap();
    assert_eq!(tc.include_thoughts, Some(true));
    assert_eq!(tc.thinking_level.as_deref(), Some("HIGH"));
    assert!(tc.thinking_budget.is_none());
}

#[test]
fn thinking_config_gemini3_custom_level() {
    let mut config = oauth_config();
    config.thinking_level =
        Some(crate::domains::model::providers::google::types::GeminiThinkingLevel::Low);
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(true, &opts).unwrap();
    assert_eq!(tc.thinking_level.as_deref(), Some("LOW"));
}

#[test]
fn thinking_config_gemini3_per_request_level_overrides_config() {
    let mut config = oauth_config();
    config.thinking_level =
        Some(crate::domains::model::providers::google::types::GeminiThinkingLevel::Low);
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions {
        thinking_level: Some("THINKING_MEDIUM".into()),
        ..Default::default()
    };
    let tc = provider.build_thinking_config(true, &opts).unwrap();
    assert_eq!(tc.thinking_level.as_deref(), Some("THINKING_MEDIUM"));
}

#[test]
fn thinking_config_gemini25_uses_budget() {
    let provider = GoogleProvider::new(api_key_config());
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(false, &opts).unwrap();
    assert_eq!(tc.include_thoughts, Some(true));
    assert!(tc.thinking_level.is_none());
    assert_eq!(tc.thinking_budget, Some(10_000));
}

#[test]
fn thinking_config_gemini25_custom_budget() {
    let mut config = api_key_config();
    config.thinking_budget = Some(20_000);
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(false, &opts).unwrap();
    assert_eq!(tc.thinking_budget, Some(20_000));
}

#[test]
fn thinking_config_gemini25_per_request_budget_overrides_config() {
    let mut config = api_key_config();
    config.thinking_budget = Some(20_000);
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions {
        gemini_thinking_budget: Some(5_000),
        ..Default::default()
    };
    let tc = provider.build_thinking_config(false, &opts).unwrap();
    assert_eq!(tc.thinking_budget, Some(5_000));
}

#[test]
fn thinking_config_none_for_non_thinking_model() {
    let mut config = api_key_config();
    config.model = "gemini-2.5-flash-lite".into();
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(false, &opts);
    assert!(tc.is_none());
}

#[test]
fn thinking_config_none_for_gemini3_flash() {
    let mut config = api_key_config();
    config.model = "gemini-3-flash-preview".into();
    let provider = GoogleProvider::new(config);
    let opts = ProviderStreamOptions::default();
    let tc = provider.build_thinking_config(true, &opts);
    assert!(
        tc.is_none(),
        "gemini-3-flash-preview should not send thinkingConfig"
    );
}

// ── System instruction ────────────────────────────────────────────

#[test]
fn system_instruction_empty_when_no_context() {
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let si = GoogleProvider::build_system_instruction(&context);
    assert!(si.is_none());
}

#[test]
fn system_instruction_from_prompt() {
    let context = Context {
        system_prompt: Some("You are helpful.".into()),
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let si = GoogleProvider::build_system_instruction(&context).unwrap();
    assert_eq!(si.parts.len(), 1);
    assert!(si.parts[0].text.contains("You are helpful."));
    assert_eq!(
        si.parts[0].text.matches("You are helpful.").count(),
        1,
        "system prompt must be included exactly once"
    );
}

// ── Request body construction ─────────────────────────────────────

#[test]
fn oauth_request_body_standard_gemini() {
    let provider = GoogleProvider::new(oauth_config());
    let context = Context {
        system_prompt: Some("Be helpful".into()),
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let opts = ProviderStreamOptions::default();
    let gc = provider.build_generation_config(&opts);
    let body = provider.build_request_body(&context, &gc);

    // Model is in URL, not body
    assert!(body.get("model").is_none());
    assert!(body.get("generationConfig").is_some());
    assert!(body.get("safetySettings").is_some());
    // thinkingConfig nested inside generationConfig, not at top level
    assert!(body["generationConfig"]["thinkingConfig"].is_object());
    assert!(body.get("thinkingConfig").is_none());
}

#[test]
fn request_body_same_format_for_oauth_and_api_key() {
    let oauth_provider = GoogleProvider::new(oauth_config());
    let api_key_provider = GoogleProvider::new(api_key_config());
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };

    let oauth_gc = oauth_provider.build_generation_config(&ProviderStreamOptions::default());
    let oauth_body = oauth_provider.build_request_body(&context, &oauth_gc);

    let api_gc = api_key_provider.build_generation_config(&ProviderStreamOptions::default());
    let api_body = api_key_provider.build_request_body(&context, &api_gc);

    // Both should have the same top-level fields (no model in body)
    assert!(oauth_body.get("model").is_none());
    assert!(api_body.get("model").is_none());
    assert!(oauth_body.get("contents").is_some());
    assert!(api_body.get("contents").is_some());
    assert!(oauth_body.get("generationConfig").is_some());
    assert!(api_body.get("generationConfig").is_some());
}

#[test]
fn api_key_request_body() {
    let provider = GoogleProvider::new(api_key_config());
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let opts = ProviderStreamOptions::default();
    let gc = provider.build_generation_config(&opts);
    let body = provider.build_request_body(&context, &gc);

    assert!(body.get("contents").is_some());
    assert!(body.get("generationConfig").is_some());
    assert!(body.get("safetySettings").is_some());
    // No model in body (it's in the URL)
    assert!(body.get("model").is_none());
}

// ── Thinking config nesting (regression tests) ─────────────────────

#[test]
fn build_gen_config_includes_thinking_for_gemini3() {
    let mut config = oauth_config();
    config.model = "gemini-3.1-pro-preview".into();
    let provider = GoogleProvider::new(config);
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    let tc = gc
        .thinking_config
        .expect("thinking config should be present for gemini-3.1-pro");
    assert_eq!(tc.thinking_level.as_deref(), Some("HIGH"));
    assert!(tc.thinking_budget.is_none());
    assert_eq!(tc.include_thoughts, Some(true));
}

#[test]
fn build_gen_config_includes_thinking_for_gemini25() {
    let mut config = api_key_config();
    config.model = "gemini-2.5-pro".into();
    let provider = GoogleProvider::new(config);
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    let tc = gc
        .thinking_config
        .expect("thinking config should be present for gemini-2.5-pro");
    assert!(tc.thinking_level.is_none());
    assert_eq!(tc.thinking_budget, Some(10_000));
    assert_eq!(tc.include_thoughts, Some(true));
}

#[test]
fn build_gen_config_no_thinking_for_non_thinking_model() {
    let mut config = api_key_config();
    config.model = "gemini-3-flash-preview".into();
    let provider = GoogleProvider::new(config);
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    assert!(gc.thinking_config.is_none());
}

#[test]
fn api_key_body_thinking_nested_not_top_level() {
    let mut config = api_key_config();
    config.model = "gemini-3.1-pro-preview".into();
    let provider = GoogleProvider::new(config);
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    let body = provider.build_request_body(&context, &gc);

    // thinkingConfig MUST be nested inside generationConfig
    assert!(
        body["generationConfig"]["thinkingConfig"].is_object(),
        "thinkingConfig must be nested inside generationConfig"
    );
    assert_eq!(
        body["generationConfig"]["thinkingConfig"]["thinkingLevel"],
        "HIGH"
    );
    // thinkingConfig MUST NOT be at top level (this was the bug)
    assert!(
        body.get("thinkingConfig").is_none(),
        "thinkingConfig must NOT be a top-level field"
    );
}

#[test]
fn oauth_body_thinking_nested_not_top_level() {
    let mut config = oauth_config();
    config.model = "gemini-3.1-pro-preview".into();
    let provider = GoogleProvider::new(config);
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    let body = provider.build_request_body(&context, &gc);

    // thinkingConfig MUST be nested inside generationConfig
    assert!(
        body["generationConfig"]["thinkingConfig"].is_object(),
        "thinkingConfig must be nested inside generationConfig"
    );
    // thinkingConfig MUST NOT be at top level
    assert!(
        body.get("thinkingConfig").is_none(),
        "thinkingConfig must NOT be a top-level field"
    );
}

#[test]
fn api_key_body_no_thinking_for_flash() {
    let mut config = api_key_config();
    config.model = "gemini-3-flash-preview".into();
    let provider = GoogleProvider::new(config);
    let context = Context {
        system_prompt: None,
        messages: vec![].into(),
        capabilities: None,
        working_directory: None,
        agent_state_context: None,
        server_origin: None,
    };
    let gc = provider.build_generation_config(&ProviderStreamOptions::default());
    let body = provider.build_request_body(&context, &gc);

    assert!(body.get("thinkingConfig").is_none());
    assert!(body["generationConfig"].get("thinkingConfig").is_none());
}

// ── parse_api_error (via shared crate::domains::model::providers::error_parsing) ─────────────

// ── Token refresh (mock server) ──────────────────────────────────

#[tokio::test]
async fn refresh_tokens_success() {
    let server = wiremock::MockServer::start().await;

    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .and(wiremock::matchers::path("/token"))
        .respond_with(
            wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "ya29.new",
                "refresh_token": "rt-new",
                "expires_in": 3600
            })),
        )
        .mount(&server)
        .await;

    let settings = GoogleApiSettings {
        token_url: Some(format!("{}/token", server.uri())),
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
    };

    let tokens = OAuthTokens {
        access_token: "ya29.old".into(),
        refresh_token: "rt-old".into(),
        expires_at: 0,
    };

    let client = reqwest::Client::new();
    let new_tokens = refresh_tokens(&tokens, &settings, &client).await.unwrap();

    assert_eq!(new_tokens.access_token, "ya29.new");
    assert_eq!(new_tokens.refresh_token, "rt-new");
    assert!(new_tokens.expires_at > crate::domains::auth::provider_credentials::now_ms());
}

#[tokio::test]
async fn refresh_tokens_preserves_old_refresh_token() {
    let server = wiremock::MockServer::start().await;

    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .and(wiremock::matchers::path("/token"))
        .respond_with(
            wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "ya29.new",
                "expires_in": 3600
            })),
        )
        .mount(&server)
        .await;

    let settings = GoogleApiSettings {
        token_url: Some(format!("{}/token", server.uri())),
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
    };

    let tokens = OAuthTokens {
        access_token: "ya29.old".into(),
        refresh_token: "rt-keep-me".into(),
        expires_at: 0,
    };

    let client = reqwest::Client::new();
    let new_tokens = refresh_tokens(&tokens, &settings, &client).await.unwrap();
    assert_eq!(new_tokens.refresh_token, "rt-keep-me");
}

#[tokio::test]
async fn refresh_tokens_failure() {
    let server = wiremock::MockServer::start().await;

    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .respond_with(wiremock::ResponseTemplate::new(401).set_body_string("Unauthorized"))
        .mount(&server)
        .await;

    let settings = GoogleApiSettings {
        token_url: Some(format!("{}/token", server.uri())),
        client_id: Some("cid".into()),
        client_secret: Some("csec".into()),
    };

    let tokens = OAuthTokens {
        access_token: "ya29.old".into(),
        refresh_token: "rt-old".into(),
        expires_at: 0,
    };

    let client = reqwest::Client::new();
    let result = refresh_tokens(&tokens, &settings, &client).await;
    assert!(result.is_err());
    assert!(matches!(result.unwrap_err(), ProviderError::Auth { .. }));
}

#[tokio::test]
async fn refresh_tokens_requires_client_id() {
    let settings = GoogleApiSettings::default(); // No client_id
    let tokens = oauth_tokens();
    let client = reqwest::Client::new();
    let result = refresh_tokens(&tokens, &settings, &client).await;
    assert!(result.is_err());
}

// ── ensure_valid_tokens ──────────────────────────────────────────

#[tokio::test]
async fn ensure_valid_tokens_skips_for_api_key() {
    let provider = GoogleProvider::new(api_key_config());
    let result = provider.ensure_valid_tokens().await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn ensure_valid_tokens_skips_refresh_when_valid() {
    let provider = GoogleProvider::new(oauth_config());
    let result = provider.ensure_valid_tokens().await;
    assert!(result.is_ok());
}
