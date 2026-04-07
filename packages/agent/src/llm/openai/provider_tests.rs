use super::*;
use crate::llm::openai::types::{
    ApiEndpoint, DEFAULT_BASE_URL, OpenAIApiSettings, OpenAIAuth, ReasoningEffort,
};

fn test_tokens() -> crate::llm::auth::OAuthTokens {
    crate::llm::auth::OAuthTokens {
        access_token: "test-token".into(),
        refresh_token: "test-refresh".into(),
        expires_at: crate::llm::auth::now_ms() + 3_600_000, // 1 hour from now
    }
}

fn test_config() -> OpenAIConfig {
    OpenAIConfig {
        model: "gpt-5.3-codex".into(),
        auth: OpenAIAuth::OAuth {
            tokens: test_tokens(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    }
}

/// Encode a string as base64url (no padding) for building test JWTs.
fn base64url_encode(input: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(input.as_bytes())
}

// ── Provider metadata ─────────────────────────────────────────────

#[test]
fn provider_type_is_openai() {
    let provider = OpenAIProvider::new(test_config());
    assert_eq!(
        provider.provider_type(),
        crate::core::messages::Provider::OpenAi
    );
}

#[test]
fn provider_model_returns_config_model() {
    let provider = OpenAIProvider::new(test_config());
    assert_eq!(provider.model(), "gpt-5.3-codex");
}

#[test]
fn provider_base_url_default() {
    let provider = OpenAIProvider::new(test_config());
    assert_eq!(provider.base_url, DEFAULT_BASE_URL);
}

#[test]
fn provider_base_url_from_config() {
    let mut config = test_config();
    config.base_url = Some("https://custom.api.com".into());
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.base_url, "https://custom.api.com");
}

#[test]
fn provider_base_url_from_settings() {
    let mut config = test_config();
    config.provider_settings.base_url = Some("https://settings.api.com".into());
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.base_url, "https://settings.api.com");
}

#[test]
fn provider_base_url_config_overrides_settings() {
    let mut config = test_config();
    config.base_url = Some("https://config.api.com".into());
    config.provider_settings.base_url = Some("https://settings.api.com".into());
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.base_url, "https://config.api.com");
}

// ── extract_account_id ────────────────────────────────────────────

#[test]
fn extract_account_id_from_valid_jwt() {
    let header = base64url_encode(r#"{"alg":"RS256","typ":"JWT"}"#);
    let payload = base64url_encode(
        r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_123456"}}"#,
    );
    let token = format!("{header}.{payload}.signature");
    assert_eq!(extract_account_id(&token), "acct_123456");
}

#[test]
fn extract_account_id_empty_for_missing_claims() {
    let header = base64url_encode(r#"{"alg":"RS256"}"#);
    let payload = base64url_encode(r#"{"sub":"user123"}"#);
    let token = format!("{header}.{payload}.sig");
    assert_eq!(extract_account_id(&token), "");
}

#[test]
fn extract_account_id_empty_for_invalid_jwt() {
    assert_eq!(extract_account_id("not-a-jwt"), "");
    assert_eq!(extract_account_id(""), "");
}

#[test]
fn extract_account_id_empty_for_invalid_json() {
    let header = base64url_encode(r#"{"alg":"RS256"}"#);
    let payload = base64url_encode("not json");
    let token = format!("{header}.{payload}.sig");
    assert_eq!(extract_account_id(&token), "");
}

#[test]
fn extract_account_id_empty_for_missing_auth_object() {
    let header = base64url_encode(r#"{"alg":"RS256"}"#);
    let payload = base64url_encode(r#"{"https://api.openai.com/auth":{}}"#);
    let token = format!("{header}.{payload}.sig");
    assert_eq!(extract_account_id(&token), "");
}

// ── token refresh (via shared crate::llm::auth::should_refresh) ────────

#[test]
fn should_refresh_when_expired() {
    let tokens = crate::llm::auth::OAuthTokens {
        access_token: "t".into(),
        refresh_token: "r".into(),
        expires_at: crate::llm::auth::now_ms().saturating_sub(600_000),
    };
    assert!(crate::llm::auth::should_refresh(&tokens, TOKEN_EXPIRY_BUFFER_MS));
}

#[test]
fn should_refresh_within_buffer() {
    let tokens = crate::llm::auth::OAuthTokens {
        access_token: "t".into(),
        refresh_token: "r".into(),
        expires_at: crate::llm::auth::now_ms() + 120_000,
    };
    assert!(crate::llm::auth::should_refresh(&tokens, TOKEN_EXPIRY_BUFFER_MS));
}

#[test]
fn should_not_refresh_when_valid() {
    let tokens = crate::llm::auth::OAuthTokens {
        access_token: "t".into(),
        refresh_token: "r".into(),
        expires_at: crate::llm::auth::now_ms() + 3_600_000,
    };
    assert!(!crate::llm::auth::should_refresh(
        &tokens,
        TOKEN_EXPIRY_BUFFER_MS
    ));
}

#[test]
fn should_refresh_at_exact_boundary() {
    let tokens = crate::llm::auth::OAuthTokens {
        access_token: "t".into(),
        refresh_token: "r".into(),
        expires_at: crate::llm::auth::now_ms() + TOKEN_EXPIRY_BUFFER_MS,
    };
    // Shared version uses >=, so at exact boundary it refreshes (safer)
    assert!(crate::llm::auth::should_refresh(&tokens, TOKEN_EXPIRY_BUFFER_MS));
}

// ── build_headers ────────────────────────────────────────────────

#[test]
fn build_headers_has_required_fields() {
    let tokens = test_tokens();
    let headers = OpenAIProvider::build_headers(&tokens, ApiEndpoint::Codex).unwrap();

    assert_eq!(
        headers[AUTHORIZATION].to_str().unwrap(),
        "Bearer test-token"
    );
    assert_eq!(headers[CONTENT_TYPE], "application/json");
    assert_eq!(headers[ACCEPT], "text/event-stream");
    assert_eq!(headers["openai-beta"], "responses=experimental");
    assert_eq!(headers["openai-originator"], "codex_cli_rs");
}

#[test]
fn build_headers_includes_account_id() {
    let header = base64url_encode(r#"{"alg":"RS256"}"#);
    let payload = base64url_encode(
        r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_789"}}"#,
    );
    let jwt = format!("{header}.{payload}.sig");

    let tokens = crate::llm::auth::OAuthTokens {
        access_token: jwt,
        refresh_token: "rt".into(),
        expires_at: 9_999_999_999_999,
    };

    let headers = OpenAIProvider::build_headers(&tokens, ApiEndpoint::Codex).unwrap();
    assert_eq!(headers["chatgpt-account-id"], "acct_789");
}

#[test]
fn build_headers_omits_account_id_for_non_jwt() {
    let tokens = crate::llm::auth::OAuthTokens {
        access_token: "simple-token".into(),
        refresh_token: "rt".into(),
        expires_at: 9_999_999_999_999,
    };

    let headers = OpenAIProvider::build_headers(&tokens, ApiEndpoint::Codex).unwrap();
    assert!(headers.get("chatgpt-account-id").is_none());
}

// ── Platform headers ─────────────────────────────────────────────

#[test]
fn platform_headers_omit_codex_headers() {
    let tokens = test_tokens();
    let headers = OpenAIProvider::build_headers(&tokens, ApiEndpoint::Platform).unwrap();

    assert_eq!(
        headers[AUTHORIZATION].to_str().unwrap(),
        "Bearer test-token"
    );
    assert_eq!(headers[CONTENT_TYPE], "application/json");
    assert_eq!(headers[ACCEPT], "text/event-stream");
    assert!(headers.get("openai-beta").is_none());
    assert!(headers.get("openai-originator").is_none());
    assert!(headers.get("chatgpt-account-id").is_none());
}

#[test]
fn platform_headers_no_account_id_even_with_jwt() {
    let header = base64url_encode(r#"{"alg":"RS256"}"#);
    let payload = base64url_encode(
        r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_789"}}"#,
    );
    let jwt = format!("{header}.{payload}.sig");

    let tokens = crate::llm::auth::OAuthTokens {
        access_token: jwt,
        refresh_token: "rt".into(),
        expires_at: 9_999_999_999_999,
    };

    let headers = OpenAIProvider::build_headers(&tokens, ApiEndpoint::Platform).unwrap();
    assert!(headers.get("chatgpt-account-id").is_none());
    assert!(headers.get("openai-beta").is_none());
}

// ── Endpoint routing ─────────────────────────────────────────────

#[test]
fn provider_endpoint_codex_for_53() {
    let provider = OpenAIProvider::new(test_config());
    assert_eq!(provider.api_endpoint, ApiEndpoint::Codex);
}

#[test]
fn provider_endpoint_oauth_54_forced_to_codex() {
    // OAuth tokens lack Platform API scopes — always routes to Codex.
    let mut config = test_config();
    config.model = "gpt-5.4".into();
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.api_endpoint, ApiEndpoint::Codex);
    assert_eq!(provider.base_url, DEFAULT_BASE_URL);
}

#[test]
fn provider_endpoint_api_key_54_uses_platform() {
    let config = OpenAIConfig {
        model: "gpt-5.4".into(),
        auth: OpenAIAuth::ApiKey {
            api_key: "sk-test-key".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    };
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.api_endpoint, ApiEndpoint::Platform);
    assert_eq!(
        provider.base_url,
        super::super::types::DEFAULT_PLATFORM_BASE_URL
    );
}

#[test]
fn provider_endpoint_api_key_codex_model_stays_codex() {
    let config = OpenAIConfig {
        model: "gpt-5.3-codex".into(),
        auth: OpenAIAuth::ApiKey {
            api_key: "sk-test-key".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    };
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.api_endpoint, ApiEndpoint::Codex);
}

#[test]
fn provider_endpoint_unknown_model_defaults_to_codex() {
    let mut config = test_config();
    config.model = "unknown-model".into();
    let provider = OpenAIProvider::new(config);
    assert_eq!(provider.api_endpoint, ApiEndpoint::Codex);
}

#[test]
fn url_codex_endpoint() {
    let provider = OpenAIProvider::new(test_config());
    let url = format!("{}{}", provider.base_url, provider.api_endpoint.path());
    assert_eq!(url, "https://chatgpt.com/backend-api/codex/responses");
}

#[test]
fn url_platform_endpoint() {
    let config = OpenAIConfig {
        model: "gpt-5.4".into(),
        auth: OpenAIAuth::ApiKey {
            api_key: "sk-test".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    };
    let provider = OpenAIProvider::new(config);
    let url = format!("{}{}", provider.base_url, provider.api_endpoint.path());
    assert_eq!(url, "https://api.openai.com/v1/responses");
}

#[test]
fn base_url_override_preserves_endpoint_path() {
    let config = OpenAIConfig {
        model: "gpt-5.4".into(),
        auth: OpenAIAuth::ApiKey {
            api_key: "sk-test".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: Some("https://custom.example.com".into()),
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    };
    let provider = OpenAIProvider::new(config);
    let url = format!("{}{}", provider.base_url, provider.api_endpoint.path());
    assert_eq!(url, "https://custom.example.com/v1/responses");
}

#[test]
fn base_url_override_codex_preserves_path() {
    let mut config = test_config();
    config.base_url = Some("https://custom.example.com".into());
    let provider = OpenAIProvider::new(config);
    let url = format!("{}{}", provider.base_url, provider.api_endpoint.path());
    assert_eq!(url, "https://custom.example.com/codex/responses");
}

// ── Tool search availability ─────────────────────────────────────

#[test]
fn tool_search_disabled_on_codex_even_for_54() {
    // OAuth → Codex, even for GPT 5.4 which declares tool_search support.
    let mut config = test_config();
    config.model = "gpt-5.4".into();
    let provider = OpenAIProvider::new(config);
    assert!(!provider.model_supports_tool_search());
}

#[test]
fn tool_search_enabled_on_platform_for_54() {
    let config = OpenAIConfig {
        model: "gpt-5.4".into(),
        auth: OpenAIAuth::ApiKey {
            api_key: "sk-test".into(),
        },
        max_tokens: None,
        temperature: None,
        base_url: None,
        reasoning_effort: None,
        provider_settings: OpenAIApiSettings::default(),
    };
    let provider = OpenAIProvider::new(config);
    assert!(provider.model_supports_tool_search());
}

#[test]
fn tool_search_disabled_for_codex_models() {
    let provider = OpenAIProvider::new(test_config());
    assert!(!provider.model_supports_tool_search());
}

// ── resolve_reasoning_effort ──────────────────────────────────────

#[test]
fn reasoning_effort_from_options() {
    let provider = OpenAIProvider::new(test_config());
    let options = ProviderStreamOptions {
        reasoning_effort: Some(ReasoningEffort::High),
        ..Default::default()
    };
    assert_eq!(provider.resolve_reasoning_effort(&options), "high");
}

#[test]
fn reasoning_effort_from_config() {
    let mut config = test_config();
    config.reasoning_effort = Some("xhigh".into());
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "xhigh");
}

#[test]
fn reasoning_effort_from_settings() {
    let mut config = test_config();
    config.provider_settings.default_reasoning_effort = Some("low".into());
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "low");
}

#[test]
fn reasoning_effort_from_model_default() {
    let provider = OpenAIProvider::new(test_config());
    let options = ProviderStreamOptions::default();
    // gpt-5.3-codex default is "medium"
    assert_eq!(provider.resolve_reasoning_effort(&options), "medium");
}

#[test]
fn reasoning_effort_options_overrides_config() {
    let mut config = test_config();
    config.reasoning_effort = Some("low".into());
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions {
        reasoning_effort: Some(ReasoningEffort::Max),
        ..Default::default()
    };
    // gpt-5.3-codex doesn't support "max" — clamps to "xhigh" (highest available)
    assert_eq!(provider.resolve_reasoning_effort(&options), "xhigh");
}

#[test]
fn reasoning_effort_config_overrides_settings() {
    let mut config = test_config();
    config.reasoning_effort = Some("high".into());
    config.provider_settings.default_reasoning_effort = Some("low".into());
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "high");
}

#[test]
fn reasoning_effort_spark_defaults_to_low() {
    let mut config = test_config();
    config.model = "gpt-5.3-codex-spark".into();
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "low");
}

#[test]
fn reasoning_effort_unknown_model_defaults_to_medium() {
    let mut config = test_config();
    config.model = "unknown-model".into();
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "medium");
}

// ── Reasoning clamping ─────────────────────────────────────────

#[test]
fn clamp_none_on_53_to_low() {
    // gpt-5.3-codex supports ["low", "medium", "high", "xhigh"] — no "none"
    assert_eq!(
        super::clamp_reasoning_effort("none", &["low", "medium", "high", "xhigh"]),
        "low"
    );
}

#[test]
fn clamp_xhigh_on_51_mini_to_high() {
    // gpt-5.1-codex-mini supports ["low", "medium", "high"] — no "xhigh"
    assert_eq!(
        super::clamp_reasoning_effort("xhigh", &["low", "medium", "high"]),
        "high"
    );
}

#[test]
fn clamp_xhigh_on_54_passthrough() {
    assert_eq!(
        super::clamp_reasoning_effort("xhigh", &["none", "low", "medium", "high", "xhigh"]),
        "xhigh"
    );
}

#[test]
fn clamp_none_on_54_passthrough() {
    assert_eq!(
        super::clamp_reasoning_effort("none", &["none", "low", "medium", "high", "xhigh"]),
        "none"
    );
}

#[test]
fn clamp_medium_passthrough() {
    assert_eq!(
        super::clamp_reasoning_effort("medium", &["low", "medium", "high"]),
        "medium"
    );
}

#[test]
fn reasoning_effort_gpt54_defaults_to_medium() {
    let mut config = test_config();
    config.model = "gpt-5.4".into();
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions::default();
    assert_eq!(provider.resolve_reasoning_effort(&options), "medium");
}

#[test]
fn reasoning_effort_gpt54_none_passthrough() {
    let mut config = test_config();
    config.model = "gpt-5.4".into();
    let provider = OpenAIProvider::new(config);
    let options = ProviderStreamOptions {
        reasoning_effort: Some(ReasoningEffort::None),
        ..Default::default()
    };
    assert_eq!(provider.resolve_reasoning_effort(&options), "none");
}

#[test]
fn reasoning_effort_none_clamped_on_53() {
    let provider = OpenAIProvider::new(test_config());
    let options = ProviderStreamOptions {
        reasoning_effort: Some(ReasoningEffort::None),
        ..Default::default()
    };
    // gpt-5.3-codex doesn't support "none" — clamp to "low"
    assert_eq!(provider.resolve_reasoning_effort(&options), "low");
}

// ── is_first_turn ────────────────────────────────────────────────

#[test]
fn first_turn_empty_messages() {
    assert!(OpenAIProvider::is_first_turn(&[]));
}

#[test]
fn first_turn_only_user_messages() {
    let messages = vec![Message::user("Hello")];
    assert!(OpenAIProvider::is_first_turn(&messages));
}

#[test]
fn not_first_turn_with_assistant() {
    use crate::core::content::AssistantContent;
    let messages = vec![
        Message::user("Hello"),
        Message::Assistant {
            content: vec![AssistantContent::text("Hi")],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        },
    ];
    assert!(!OpenAIProvider::is_first_turn(&messages));
}

// ── parse_api_error (via shared crate::llm::error_parsing) ─────────────

// ── to_standard_base64 ──────────────────────────────────────────

#[test]
fn base64url_to_standard_replaces_chars() {
    let result = to_standard_base64("abc-def_ghi");
    assert_eq!(result, "abc+def/ghi=");
}

#[test]
fn base64url_to_standard_adds_padding() {
    assert_eq!(to_standard_base64("YQ"), "YQ==");
    assert_eq!(to_standard_base64("YWI"), "YWI=");
    assert_eq!(to_standard_base64("YWJj"), "YWJj");
}

// ── Token refresh (mock server) ──────────────────────────────────

#[tokio::test]
async fn refresh_tokens_success() {
    let server = wiremock::MockServer::start().await;

    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .and(wiremock::matchers::path("/oauth/token"))
        .respond_with(
            wiremock::ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "access_token": "new-access-token",
                "refresh_token": "new-refresh-token",
                "expires_in": 3600
            })),
        )
        .mount(&server)
        .await;

    let settings = OpenAIApiSettings {
        token_url: Some(format!("{}/oauth/token", server.uri())),
        ..Default::default()
    };

    let client = reqwest::Client::new();
    let tokens = refresh_tokens("old-refresh-token", &settings, &client)
        .await
        .unwrap();

    assert_eq!(tokens.access_token, "new-access-token");
    assert_eq!(tokens.refresh_token, "new-refresh-token");
    assert!(tokens.expires_at > crate::llm::auth::now_ms());
}

#[tokio::test]
async fn refresh_tokens_failure() {
    let server = wiremock::MockServer::start().await;

    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .and(wiremock::matchers::path("/oauth/token"))
        .respond_with(wiremock::ResponseTemplate::new(401).set_body_string("Unauthorized"))
        .mount(&server)
        .await;

    let settings = OpenAIApiSettings {
        token_url: Some(format!("{}/oauth/token", server.uri())),
        ..Default::default()
    };

    let client = reqwest::Client::new();
    let result = refresh_tokens("bad-token", &settings, &client).await;

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(matches!(err, ProviderError::Auth { .. }));
    assert!(err.to_string().contains("401"));
}

// ── ensure_valid_tokens ──────────────────────────────────────────

#[tokio::test]
async fn ensure_valid_tokens_skips_refresh_when_valid() {
    let provider = OpenAIProvider::new(test_config());
    // Tokens expire in 1 hour, no refresh needed
    let result = provider.ensure_valid_tokens().await;
    assert!(result.is_ok());
}

// ── DEFAULT_INSTRUCTIONS ─────────────────────────────────────────

#[test]
fn instructions_not_empty() {
    assert!(!DEFAULT_INSTRUCTIONS.is_empty());
    assert!(DEFAULT_INSTRUCTIONS.contains("Codex"));
}
